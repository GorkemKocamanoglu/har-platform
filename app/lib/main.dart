import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:meta_wearables_dat_flutter/meta_wearables_dat_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'har_classifier.dart';

void main() {
  runApp(const MaterialApp(home: HARDataLogger(), debugShowCheckedModeBanner: false));
}

class HARDataLogger extends StatefulWidget {
  const HARDataLogger({super.key});

  @override
  State<HARDataLogger> createState() => _HARDataLoggerState();
}

class _HARDataLoggerState extends State<HARDataLogger> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  Map<String, BluetoothDevice> connectedDevices = {};
  Map<String, BluetoothCharacteristic> activeCharacteristics = {};
  Map<String, StreamSubscription> _valueSubscriptions = {};
  Map<String, StreamSubscription> _connectionSubscriptions = {};

  // --- per-device health monitoring ---
  Map<String, int> packetCounts = {};      // total packets this session
  Map<String, int> lastPacketMs = {};      // wall-clock ms of last packet
  Map<String, int> malformedCounts = {};   // packets that didn't parse to 6 fields
  Timer? _healthTimer;                     // refreshes the status indicators

  // --- live activity prediction ---
  HarClassifier? _classifier;
  String _livePrediction = "--";
  Timer? _predictTimer;

  // --- Meta glasses (DAT) ---
  bool _glassesRegistered = false;
  bool _registering = false;

  final List<String> targetDeviceNames = [
    "HARNode_Ankle_Right",
    "HARNode_Ankle_Left",
    "HARNode_Wrist_Right",
    "HARNode_Wrist_Left"
  ];

  String? primaryDeviceForChart;
  bool isScanning = false;
  bool isRecording = false;
  StreamSubscription? _scanSubscription;

  final String SERVICE_UUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  final String CHARACTERISTIC_UUID = "beb5483e-36e1-4688-b7f5-ea07361b26a8";

  // The dropdown is now a GROUND-TRUTH HINT stored in session metadata,
  // not the label itself (labels come from the VLM pipeline).
  String selectedLabel = "Walking";
  final List<String> activities = [
    "Walking", "Running", "Standing", "Sitting", "Cycling",
    "Car", "Bus", "Train", "Scooter", "Mixed", "Other"
  ];
  final String wearerId = "P01"; // change per person wearing the sensors

  // --- streaming write state ---
  IOSink? _csvSink;
  List<String> _writeBuffer = [];
  Timer? _flushTimer;
  Directory? _currentSessionDir;
  String? _currentSessionId;
  int? _recordingStartMs;

  // --- recording duration ---
  int? _recordingLimitMinutes;   // null = unlimited (manual stop only)
  Timer? _autoStopTimer;
  final List<int?> _durationOptions = [null, 3, 5]; // null = manual

  // --- chart (throttled) ---
  List<FlSpot> dataX = [];
  List<FlSpot> dataY = [];
  List<FlSpot> dataZ = [];
  final List<List<double>> _chartBuffer = []; // [ax, ay, az] pending points
  Timer? _chartTimer;
  double timeCounter = 0;

  List<Directory> savedSessions = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_loadSavedSessions);

    FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        startScan();
      }
    });

    // load the on-device activity model (assets/har_model.json)
    HarClassifier.loadFromAsset('assets/har_model.json').then((c) {
      if (mounted) setState(() => _classifier = c);
    }).catchError((e) {
      debugPrint("Could not load har_model.json: $e");
    });

    // predict once per second from the rolling sensor buffers
    _predictTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final result = _classifier?.predictWithConfidence();
      setState(() {
        _livePrediction = result == null
            ? "--"
            : "${result.$1}  ${(result.$2 * 100).round()}%";
      });
    });

    // repaint chart at 10 Hz instead of on every BLE packet
    _chartTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _drainChartBuffer());
    // refresh device-health indicators at 1 Hz
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
      _warnIfNodeStale();
    });

    _loadSavedSessions();
  }

  @override
  void dispose() {
    _chartTimer?.cancel();
    _healthTimer?.cancel();
    _predictTimer?.cancel();
    _flushTimer?.cancel();
    _autoStopTimer?.cancel();
    _scanSubscription?.cancel();
    for (final s in _valueSubscriptions.values) { s.cancel(); }
    for (final s in _connectionSubscriptions.values) { s.cancel(); }
    _csvSink?.close();
    super.dispose();
  }

  // ============================================================ Meta glasses (DAT)

  Future<void> _registerGlasses() async {
    setState(() => _registering = true);
    try {
      // Android runtime permissions the DAT SDK needs (no-op on iOS)
      await MetaWearablesDat.requestAndroidPermissions();
      // Deep-links into the Meta AI app; user taps Allow; Meta AI links back.
      // Requires Developer Mode toggled ON in the Meta AI app settings.
      await MetaWearablesDat.startRegistration();

      if (mounted) {
        setState(() => _glassesRegistered = true);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Glasses registered!"),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      debugPrint("Glasses registration error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Glasses registration failed: $e"),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 8),
        ));
      }
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  // ============================================================ BLE

  void startScan() async {
    setState(() => isScanning = true);

    // single scan subscription — repeated startScan calls must not stack listeners
    _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        String deviceName = r.device.platformName;
        if (targetDeviceNames.contains(deviceName) && !connectedDevices.containsKey(deviceName)) {
          setState(() {
            connectedDevices[deviceName] = r.device;
            primaryDeviceForChart ??= deviceName;
          });
          connectToDevice(r.device, deviceName);
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    Future.delayed(const Duration(seconds: 10), () {
      if (mounted) setState(() => isScanning = false);
    });
  }

  void connectToDevice(BluetoothDevice device, String deviceName) async {
    try {
      await device.connect(license: License.nonprofit);

      // watch for disconnects — the silent killer of recordings
      _connectionSubscriptions[deviceName]?.cancel();
      _connectionSubscriptions[deviceName] =
          device.connectionState.listen((BluetoothConnectionState state) {
        if (state == BluetoothConnectionState.disconnected) {
          if (mounted) {
            setState(() {}); // health indicator turns red via lastPacketMs staleness
            if (isRecording) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text("WARNING: $deviceName DISCONNECTED during recording!"),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 5),
              ));
            }
          }
          // modest auto-reconnect attempt
          Future.delayed(const Duration(seconds: 2), () async {
            try {
              await device.connect(license: License.nonprofit);
              discoverServices(device, deviceName);
            } catch (_) {/* next health tick keeps showing red */}
          });
        }
      });

      discoverServices(device, deviceName);
    } catch (e) {
      debugPrint("Connection Error ($deviceName): $e");
    }
  }

  void discoverServices(BluetoothDevice device, String deviceName) async {
    List<BluetoothService> services = await device.discoverServices();
    for (BluetoothService service in services) {
      if (service.uuid.toString() == SERVICE_UUID) {
        for (BluetoothCharacteristic characteristic in service.characteristics) {
          if (characteristic.uuid.toString() == CHARACTERISTIC_UUID) {
            activeCharacteristics[deviceName] = characteristic;
            await characteristic.setNotifyValue(true);

            // cancel any previous listener for this device (reconnects!)
            _valueSubscriptions[deviceName]?.cancel();
            _valueSubscriptions[deviceName] =
                characteristic.lastValueStream.listen((value) {
              if (value.isEmpty) return;
              String decodedData = utf8.decode(value, allowMalformed: true).trim();
              List<String> parts = decodedData.split(',');

              final nowMs = DateTime.now().millisecondsSinceEpoch;
              if (parts.length == 6) {
                packetCounts[deviceName] = (packetCounts[deviceName] ?? 0) + 1;
                lastPacketMs[deviceName] = nowMs;

                // parse all 6 axes once, reuse for recording/chart/classifier
                final ax = double.tryParse(parts[0]) ?? 0.0;
                final ay = double.tryParse(parts[1]) ?? 0.0;
                final az = double.tryParse(parts[2]) ?? 0.0;
                final gx = double.tryParse(parts[3]) ?? 0.0;
                final gy = double.tryParse(parts[4]) ?? 0.0;
                final gz = double.tryParse(parts[5]) ?? 0.0;

                if (isRecording) {
                  _writeBuffer.add("$nowMs,$deviceName,$decodedData");
                }

                // feed the live activity classifier (rolling 2s buffers)
                _classifier?.addSample(deviceName, nowMs, ax, ay, az, gx, gy, gz);

                if (deviceName == primaryDeviceForChart) {
                  _chartBuffer.add([ax, ay, az]); // no setState here — timer drains it
                }
              } else {
                malformedCounts[deviceName] = (malformedCounts[deviceName] ?? 0) + 1;
              }
            });
          }
        }
      }
    }
  }

  void _warnIfNodeStale() {
    if (!isRecording || !mounted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final name in connectedDevices.keys) {
      final last = lastPacketMs[name];
      if (last != null && now - last > 5000) {
        // stale >5s during recording: surface it once per staleness episode
        // (indicator dot is already red; snackbar only on the transition)
        if (now - last < 6000) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("WARNING: no data from $name for 5s!"),
            backgroundColor: Colors.orange,
          ));
        }
      }
    }
  }

  // ============================================================ chart

  void _drainChartBuffer() {
    if (_chartBuffer.isEmpty || !mounted) return;
    setState(() {
      for (final p in _chartBuffer) {
        timeCounter += 0.02;
        dataX.add(FlSpot(timeCounter, p[0]));
        dataY.add(FlSpot(timeCounter, p[1]));
        dataZ.add(FlSpot(timeCounter, p[2]));
      }
      _chartBuffer.clear();
      while (dataX.length > 100) {
        dataX.removeAt(0);
        dataY.removeAt(0);
        dataZ.removeAt(0);
      }
    });
  }

  // ============================================================ recording

  String _makeSessionId() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return "${n.year}-${p(n.month)}-${p(n.day)}_${p(n.hour)}${p(n.minute)}${p(n.second)}"
        "_${selectedLabel.toLowerCase().replaceAll(' ', '')}";
  }

  String _positionFromName(String deviceName) {
    // "HARNode_Wrist_Left" -> "wrist_left"
    return deviceName.replaceFirst("HARNode_", "").toLowerCase();
  }

  Future<void> startRecording() async {
    final docs = await getApplicationDocumentsDirectory();
    _currentSessionId = _makeSessionId();
    _currentSessionDir = Directory('${docs.path}/sessions/$_currentSessionId');
    await _currentSessionDir!.create(recursive: true);

    final csvFile = File('${_currentSessionDir!.path}/sensors.csv');
    _csvSink = csvFile.openWrite(mode: FileMode.write);
    _csvSink!.writeln("Timestamp_ms,Device_Name,AccX,AccY,AccZ,GyroX,GyroY,GyroZ");

    packetCounts.clear();
    malformedCounts.clear();
    _writeBuffer.clear();
    _recordingStartMs = DateTime.now().millisecondsSinceEpoch;

    // flush buffered lines to disk every 2 seconds — a crash loses at most 2s
    _flushTimer = Timer.periodic(const Duration(seconds: 2), (_) => _flushBuffer());

    setState(() => isRecording = true);

    // auto-stop after the selected limit (manual stop still works as early exit)
    _autoStopTimer?.cancel();
    if (_recordingLimitMinutes != null) {
      _autoStopTimer = Timer(Duration(minutes: _recordingLimitMinutes!), () {
        if (isRecording) stopRecording();
      });
    }
  }

  void _flushBuffer() {
    if (_csvSink == null || _writeBuffer.isEmpty) return;
    final lines = List<String>.from(_writeBuffer);
    _writeBuffer.clear();
    for (final l in lines) {
      _csvSink!.writeln(l);
    }
  }

  Future<void> stopRecording() async {
    setState(() => isRecording = false);
    _flushTimer?.cancel();
    _autoStopTimer?.cancel();
    _flushBuffer();
    await _csvSink?.flush();
    await _csvSink?.close();
    _csvSink = null;

    final stopMs = DateTime.now().millisecondsSinceEpoch;

    // ---- session.json: device identifiers, body positions, timing, ground-truth hint
    final meta = {
      "session_id": _currentSessionId,
      "wearer_id": wearerId,
      "recording_start_ms": _recordingStartMs,
      "recording_stop_ms": stopMs,
      "duration_s": ((stopMs - (_recordingStartMs ?? stopMs)) / 1000).round(),
      "duration_limit_minutes": _recordingLimitMinutes,   // null = manual stop
      "ground_truth_hint": selectedLabel,
      "video_source": "meta_glasses_separate", // video recorded on glasses, pulled manually
      "timestamp_source": "phone_clock_at_ble_arrival",
      "devices": connectedDevices.keys.map((name) => {
            "name": name,
            "position": _positionFromName(name),
            "packets_received": packetCounts[name] ?? 0,
            "malformed_packets": malformedCounts[name] ?? 0,
          }).toList(),
    };
    final metaFile = File('${_currentSessionDir!.path}/session.json');
    await metaFile.writeAsString(const JsonEncoder.withIndent("  ").convert(meta));

    // ---- post-recording sanity check: did every connected node actually log?
    final silent = connectedDevices.keys
        .where((n) => (packetCounts[n] ?? 0) == 0)
        .toList();
    if (mounted) {
      if (silent.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Saved, BUT NO DATA from: ${silent.join(', ')}"),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 8),
        ));
      } else {
        final counts = connectedDevices.keys
            .map((n) => "$n: ${packetCounts[n]}")
            .join(", ");
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Saved $_currentSessionId  ($counts)"),
          backgroundColor: Colors.green,
        ));
      }
    }
    _loadSavedSessions();
  }

  void toggleRecording() async {
    if (isRecording) {
      await stopRecording();
    } else {
      await startRecording();
    }
  }

  // ============================================================ history

  Future<void> _loadSavedSessions() async {
    final docs = await getApplicationDocumentsDirectory();
    final sessionsRoot = Directory('${docs.path}/sessions');
    if (!await sessionsRoot.exists()) {
      setState(() => savedSessions = []);
      return;
    }
    final dirs = sessionsRoot.listSync().whereType<Directory>().toList();
    dirs.sort((a, b) => b.path.compareTo(a.path)); // ids sort chronologically
    setState(() => savedSessions = dirs);
  }

  Future<void> _shareSession(Directory dir) async {
    final files = dir
        .listSync()
        .whereType<File>()
        .map((f) => XFile(f.path))
        .toList();
    if (files.isNotEmpty) {
      await Share.shareXFiles(files, text: 'HAR session: ${dir.path.split('/').last}');
    }
  }

  Future<void> _deleteSession(Directory dir) async {
    final name = dir.path.split('/').last;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete session?"),
        content: Text("Permanently delete '$name'?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Delete", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      dir.deleteSync(recursive: true);
      _loadSavedSessions();
    }
  }

  // ============================================================ UI

  Color _deviceStatusColor(String name) {
    final last = lastPacketMs[name];
    if (last == null) return Colors.grey;
    final age = DateTime.now().millisecondsSinceEpoch - last;
    if (age < 2000) return Colors.green;
    if (age < 5000) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('HAR Multi-Node (${connectedDevices.length}/4)'),
        backgroundColor: Colors.blueAccent,
        actions: [
          // --- Meta glasses registration (DAT Phase 2 smoke test) ---
          IconButton(
            icon: _registering
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Icon(
                    _glassesRegistered ? Icons.videocam : Icons.videocam_off,
                    color: _glassesRegistered ? Colors.greenAccent : Colors.white,
                  ),
            tooltip: _glassesRegistered ? 'Glasses registered' : 'Register glasses',
            onPressed: _registering ? null : _registerGlasses,
          ),
          IconButton(
            icon: isScanning
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.refresh),
            tooltip: 'Rescan for nodes',
            onPressed: isScanning ? null : startScan,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.show_chart), text: "Live Data"),
            Tab(icon: Icon(Icons.folder), text: "Sessions"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildLiveTab(),
          _buildHistoryTab(),
        ],
      ),
    );
  }

  Widget _buildLiveTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildDeviceStatusList()),
              DropdownButton<String>(
                value: selectedLabel,
                items: activities
                    .map((act) => DropdownMenuItem(value: act, child: Text(act)))
                    .toList(),
                onChanged: isRecording
                    ? null
                    : (value) => setState(() => selectedLabel = value!),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // --- live activity prediction ---
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: Colors.blueAccent.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                Text(
                  _classifier == null ? "model not loaded" : "Live activity",
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                Text(
                  _livePrediction,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          if (primaryDeviceForChart != null)
            Text(
              "Live Graph (Showing: $primaryDeviceForChart)",
              style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(10)),
              child: dataX.isEmpty
                  ? const Center(child: Text("Waiting for data..."))
                  : LineChart(
                      LineChartData(
                        gridData: FlGridData(show: true),
                        titlesData: FlTitlesData(show: false),
                        borderData: FlBorderData(show: true),
                        minY: -2.0,
                        maxY: 2.0,
                        lineBarsData: [
                          LineChartBarData(spots: dataX, isCurved: true, color: Colors.blue, dotData: FlDotData(show: false)),
                          LineChartBarData(spots: dataY, isCurved: true, color: Colors.green, dotData: FlDotData(show: false)),
                          LineChartBarData(spots: dataZ, isCurved: true, color: Colors.red, dotData: FlDotData(show: false)),
                        ],
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 20),
          // --- recording duration selector ---
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("Duration: ", style: TextStyle(fontSize: 14)),
              const SizedBox(width: 8),
              ..._durationOptions.map((opt) {
                final label = opt == null ? "Manual" : "$opt min";
                final selected = _recordingLimitMinutes == opt;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: selected,
                    onSelected: isRecording
                        ? null
                        : (_) => setState(() => _recordingLimitMinutes = opt),
                  ),
                );
              }),
            ],
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: connectedDevices.isNotEmpty ? toggleRecording : null,
            icon: Icon(isRecording ? Icons.stop : Icons.fiber_manual_record),
            label: Text(isRecording
                ? "Stop & Save Session"
                : _recordingLimitMinutes == null
                    ? "Start Recording  (hint: $selectedLabel)"
                    : "Start ${_recordingLimitMinutes}min  (hint: $selectedLabel)"),
            style: ElevatedButton.styleFrom(
              backgroundColor: isRecording ? Colors.red : Colors.green,
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
              textStyle: const TextStyle(fontSize: 18),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceStatusList() {
    if (connectedDevices.isEmpty) {
      return Text(
        isScanning ? 'Scanning for nodes...' : 'Disconnected',
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.red),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Devices:',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.green)),
        const SizedBox(height: 4),
        ...connectedDevices.keys.map((name) => Row(
              children: [
                Icon(Icons.circle, size: 10, color: _deviceStatusColor(name)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    "$name  (${packetCounts[name] ?? 0})",
                    style: const TextStyle(fontSize: 12, color: Colors.black87),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            )),
      ],
    );
  }

  Widget _buildHistoryTab() {
    return savedSessions.isEmpty
        ? const Center(child: Text("No recordings yet."))
        : ListView.builder(
            itemCount: savedSessions.length,
            itemBuilder: (context, index) {
              final dir = savedSessions[index];
              final name = dir.path.split('/').last;
              int totalKb = 0;
              for (final f in dir.listSync().whereType<File>()) {
                totalKb += f.lengthSync();
              }
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: ListTile(
                  leading: const Icon(Icons.insert_chart, color: Colors.blue),
                  title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text("${(totalKb / 1024).toStringAsFixed(1)} KB"),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.share, color: Colors.green),
                        onPressed: () => _shareSession(dir),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _deleteSession(dir),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
  }
}