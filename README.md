# HAR Data Platform — Automated Recording & Labeling for Human Activity Recognition



## Repository contents

| File / notebook | Role |
|---|---|
| `main.dart`, `har_classifier.dart` | Flutter recording app + on-device activity prediction |
| `har_pipeline.py` | **Authoritative** labeling pipeline (importable module; lives in Drive) |
| `HAR_Batch.ipynb` | One-click batch labeling of all unprocessed sessions in Drive |
| `HAR_Training.ipynb` | Feature extraction, leave-one-session-out evaluation, Random Forest, model export |
| `HAR_Pipeline_v2.ipynb` | Step-by-step version of the pipeline with diagnostic plots — use for **debugging and documentation**; `har_pipeline.py` is the master copy of the logic |
| Arduino sketch | BLE firmware for the M5AtomS3 HARNodes (6-axis IMU over BLE notify) |

---

## Installation

### Phone
1. Install the  app 
2. Install the **Meta AI** app (App Store / Google Play) and pair the glasses.
3. Make sure **Google Drive** is installed and signed in.

### Sensors (skip if HARNodes are already flashed)
4. Open the Arduino IDE, upload the BLE Arduino sketch to each M5AtomS3 chip.
   Device names must contain the body position: `HARNode_Wrist_Left`,
   `HARNode_Wrist_Right` (also supported: `HARNode_Ankle_Left/Right`).

### Cloud (one-time)
5. In Google Drive, create the folder **`HAR_data/`** containing:
   - `sessions/` — one subfolder per recording (created automatically when
     sharing from the app)
   - `inbox_videos/` — drop glasses videos here for automatic pairing
   - `har_pipeline.py` — the pipeline module
6. In Google Colab, upload `HAR_Batch.ipynb` and `HAR_Training.ipynb`
   (File → Upload notebook). Add your Gemini API key as a Colab secret named
   `GEMINI_API_KEY`

---

## Usage

### Recording a session
1. Switch the HARNodes **on** and open the app. The app scans automatically;
   use the refresh button in the top bar to rescan.
2. As sensors connect, each appears with a **status dot** . The chart shows the
   XYZ acceleration of one sensor so you can verify signals look right.
3. Strap the HARNodes onto your wrists **the same way every time** (e.g. on-off
   toggle text readable from your point of view). 
4. Choose a **duration**: *Manual* (stop by hand) or an auto-stop after 3 / 5
   minutes. If you use auto-stop, set the glasses to a matching or longer
   recording length.
5. **Start both recordings back-to-back**: press and hold the capture button on
   the glasses, and immediately start recording in the app.
6. Do your activities. If **Live activity recognition** is toggled on, the app
   shows its current prediction (with confidence) from the latest installed
   model.
7. Stop the **glasses first**, then the app. 
8. **Read the save message.** Green = all nodes logged (with packet counts).
   Red = a node delivered no data — the session is incomplete; re-record.

### Getting data into the cloud
9. In the app's **Sessions** tab, share the session folder to Drive →
    `HAR_data/sessions/`. Each session is a folder containing `sensors.csv`
    (raw IMU rows) and `session.json` (device IDs, body positions, timing,
    wearer ID, ground-truth hint, packet counts).
10. When the glasses video has synced to the phone, upload it to
    `HAR_data/inbox_videos/` — **original file, original name**. The batch
    notebook pairs videos with sessions automatically by comparing the video's
    metadata start time with each session's sensor start time.

### Labeling 
11. Open `HAR_Batch.ipynb` in Colab → **Runtime → Run all** → authorize Drive.
    
### Training
12. Open `HAR_Training.ipynb` → **Run all**. It recomputes 39 IMU features per
    window across all sessions and evaluates with **leave-one-session-out**
    cross-validation (windows from one recording never appear in both train and
    test — random splits would leak and report inflated accuracy). Outputs:
    per-session accuracies, per-class precision/recall, a confusion matrix, and
    feature importances.
13. Run the **export cell** at the end to produce `har_model.json` (a compact
    forest for the phone) in `HAR_data/`.

### Deploying the model to the phone
14. Copy `har_model.json` into the Flutter project's `assets/` folder (declared
    in `pubspec.yaml`), rebuild the app (full restart — hot reload does not load
    new assets). The app now predicts with the new model.

---

## Configuration 

### Labeling pipeline (`har_pipeline.py`, tunables at the top)
| Parameter | Default | Meaning |
|---|---|---|
| `WINDOW_MS` / `STEP_MS` | 2000 / 1000 | Window length and stride |
| `ACC_STD_MIN` | 0.07 g | Minimum motion energy for locomotion |
| `FREQ_MATCH_HZ` | 0.65 | Cadence agreement tolerance between wrists (harmonic-aware: f vs 2f pairs count as agreement) |
| `RUN_FREQ_HZ` / `RUN_ACC_STD` | 2.4 Hz / 0.60 g | Walking→Running boundary |
| `MIN_SEGMENT_S` | 5.0 | Segments shorter than this are absorbed into neighbors (a 2 s pause does not split a walk) |
| `MAX_VLM_CHUNK_S` | 25.0 | Max duration one VLM call covers — context changing mid-segment (hallway→stairs→street) is still captured |

### Taxonomy — how training classes are defined
(`context`, `action`); training classes are derived by an **ordered rule list**
(`DEFAULT_TAXONOMY` in `har_pipeline.py`, or the taxonomy cell in the
notebooks). First matching rule wins, unmatched windows become `Other` and are
reported. To change the class list: edit the rules, re-run — **no API calls, no
re-labeling, and every past recording gets the new classes retroactively.**

### Training notebook (cell #1)
| Parameter | Meaning |
|---|---|
| `LABEL_COLUMN` | `"Label"` (taxonomy classes) or `"Motion"` (Idle/Walking/Running smoke test) |
| `DROP_TRANSITION_WINDOWS` | Drop windows adjacent to a label change (boundary noise) |
| `MIN_SESSIONS_PER_CLASS` | Classes seen in fewer sessions are dropped with a warning — they cannot be evaluated honestly |




## The Flutter side

Dependencies (see `pubspec.yaml` for exact versions):
- `flutter_blue_plus` — BLE connection to the HARNodes
- `path_provider` — session storage on the phone
- `share_plus` — sharing session folders to Drive
- `fl_chart` — live signal chart
- `meta_wearables_dat_flutter` *(experimental)* — Meta glasses streaming



