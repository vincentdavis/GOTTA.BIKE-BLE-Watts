# CLAUDE.md

## Project
Flutter app that turns a phone into a BLE **peripheral** emulating a standard
Cycling Power Service (CPS, `0x1818`) sensor — it broadcasts instantaneous power
and cadence to head units, Zwift, Garmin/Wahoo apps, and nRF Connect. It can
also emulate a Heart Rate (`0x180D`) and a Cycling Speed and Cadence (`0x1816`)
sensor (Settings › Sensors; at least one service is always on). It is a
*sensor*, not a controllable trainer: no FTMS / ERG resistance control.
**Dual record** (app-bar action) turns the phone into a BLE *central*
instead: it connects to two real sensors, shows them side by side and
records both to a CSV. Record-only, no rebroadcast (yet).

## Stack
- Flutter (Dart >=3.1.3, Flutter >=3.3.0)
- BLE: `universal_ble` ^2.0.4 — peripheral / GATT-server + advertising
- `wakelock_plus` (keep screen on while advertising / dual recording);
  `shared_preferences` (persist presets, device identity, profiles, the
  sensor selection and the screen-off setting); `path_provider` +
  `share_plus` (save Dual-record CSVs, share them)
- Android only: a small native foreground service (Kotlin, no plugin) for
  the optional "keep broadcasting with screen off" mode.
- Material 3, dark theme. No state-management package; plain `StatefulWidget`.

## Layout
- `lib/cpm_codec.dart` — pure-Dart protocol core. `CrankSimulator` turns a target
  cadence into honest crank counters; `CpmCodec` packs the 8-byte `0x2A63` packet.
  Keep this free of any `universal_ble` imports so the BLE library can be swapped
  without touching protocol logic.
- `lib/hr_codec.dart` — pure Heart Rate core: `HeartRateCodec` packs `0x2A37`
  (uint8/uint16 bpm, contact bits, up to 8 RR intervals); `BeatSimulator`
  turns a bpm into RR intervals. Same purity rule as `cpm_codec.dart`.
- `lib/csc_codec.dart` — pure Speed & Cadence core: `CscCodec` packs `0x2A5B`
  (wheel and/or crank data) and the `0x2A5C` feature; `WheelSimulator` turns a
  speed + wheel circumference into honest wheel counters.
- `lib/sensor_config.dart` — pure `SensorConfig` (enabled services, manual
  heart rate / speed, wheel circumference; `normalized()` keeps one service
  on and clamps) + `SensorConfigStore` (`shared_preferences`).
- `lib/cps_peripheral.dart` — the only `universal_ble` glue. `setup()`
  registers Device Information (`0x180A`, always) plus the enabled sensor
  services; calls are serialised and re-register only when the selection
  changed. One read handler serves Feature (`0x2A65`) / Sensor Location
  (`0x2A5D`) / Body Sensor Location (`0x2A38`) / CSC Feature (`0x2A5C`) /
  Manufacturer (`0x2A29`) / Model (`0x2A24`), slicing long values by the
  request offset. Advertises only the enabled sensor services under
  `advertisedName`, and `pushMeasurement` sends one notification per enabled
  sensor, advancing the shared `CrankSimulator` once per tick.
- `lib/main.dart` — UI with a Manual / Test-profile mode switch. Manual: +/-
  steppers for each enabled sensor — power (step 5 W), cadence (1 rpm), speed
  (1 km/h), heart rate (1 bpm) — plus preset chips. Test-profile: plays the
  `PowerProfile` selected in the profile library (picker locked while a
  profile runs); heart rate and speed keep their manual values. Start/Stop
  advertising and the status line live in `_BroadcastBar`, pinned to the
  bottom (`bottomNavigationBar`) so they're always visible; problem messages
  are shown in the error colour. A live connected-apps count is in the
  readout. A 500 ms timer (`_onTick`) pushes `_broadcastValues` each tick:
  the running profile; else 0 W / 0 rpm in Test profile mode (never an
  unseen manual value before a run or after a coast-down); else the manual
  values. Stopping the broadcast (any reason) also ends a running profile,
  so a run never silently resumes after a gap. `test/emulator_page_test.dart`
  drives the whole screen with fake BLE platforms.
- `lib/presets.dart` — pure `Preset` (power, cadence) model + `PresetStore`
  (`shared_preferences` persistence, max 5, sensible defaults). Keep the model
  pure/testable like `cpm_codec.dart`.
- `lib/settings_page.dart` — Settings screen: sensor switches (locked while
  advertising; the last one on can't be turned off) and wheel circumference,
  the screen-off switch (Android only; applies immediately), the device
  identity (name, manufacturer, model), and add/edit/delete the presets.
- `lib/screen_off_mode.dart` — "keep broadcasting with screen off":
  `ScreenOffService` (method channel `gotta.bike/keep_alive`),
  `KeepAwake` (serialised; while advertising it always holds the screen
  wakelock, plus the service in screen-off mode, keeping just the wakelock
  if the service can't start) and `ScreenOffStore`.
- `android/app/src/main/kotlin/com/example/cps_emulator/` —
  `BroadcastKeepAliveService.kt` (`connectedDevice` foreground service +
  partial wake lock + ongoing notification with a Stop action; runs no
  Dart) and `MainActivity.kt` (the channel, the Android 13+ notification
  permission request, and stopping the service when the activity finishes).
  The notification icon is `res/drawable/ic_stat_broadcast.xml`.
- `lib/sensor_decoders.dart` — pure central-side decoders (no BLE imports):
  `SensorDecoders` for `0x2A63` (walks every flag field, records
  balance/torque/wheel/crank/energy, skips extreme/dead-spot fields),
  `0x2A37`, `0x2A5B` and FTMS Indoor Bike Data `0x2AD2`; each returns null
  on a short packet. `RevolutionRateTracker` turns revs/event-time deltas
  into a rate; `MeasurementInterpreter` (one per device) turns packets into
  flat `SensorSample`s with derived cadence/speed.
- `lib/dual_recorder.dart` — pure `DualRecorder`: slots A/B, running
  per-slot averages (`stats` picks ONE power source per slot: CPS, else
  FTMS; cadence CPS > FTMS > CSC), B-vs-A difference and the CSV
  (`csvHeader`; one row per notification, not resampled; `raw_hex`).
- `lib/sensor_central.dart` — `universal_ble` central glue: `CentralUuids`,
  `SensorScanner`, and `SensorLink` (one device: connect, discover,
  subscribe to every supported measurement, re-connect with back-off until
  `close`). It emits raw `SensorPacket`s only, so a future relay can reuse
  it with `cps_peripheral.dart`.
- `lib/recording_files.dart` — saves CSVs to app documents `recordings/`
  and opens the share sheet (`share_plus`). Tests fake it.
- `lib/dual_record_page.dart` — the Dual record screen: two slot cards,
  scan sheet, live values, comparison card, record/stop/share. Opened only
  while not advertising; leaving while recording asks, then stops and
  saves.
- `lib/device_identity.dart` — pure `DeviceIdentity` (advertised name +
  Manufacturer/Model for the DIS) + `DeviceIdentityStore` (`shared_preferences`),
  plus the advertisement name budget (`advertisedNameBudget`,
  `fitAdvertisedName`). The MAC address is OS-assigned and not settable.
- `lib/limits.dart` — pure shared bounds (`kPowerMax`, `kCadenceMax`);
  `presets.dart` re-exports it. Pure files must import this, not
  `presets.dart` (which pulls in `shared_preferences`).
- `lib/power_profile.dart` — pure `PowerProfile` / `ProfileSegment` model
  (timed power/cadence segments, ramps, coasts; `sampleAt(t)`; stable ids;
  built-in vs custom; JSON with clamping; `validate()`). A custom profile can
  instead be a **recorded ride**: `track` (`PowerTrack`, per-second power
  0..`kTrackPowerMax` (3000 W, above the 800 W manual limit) + cadence, up to
  `kMaxTrackSec` = 6 h, no segments, stored as base64 uint16/uint8 in the
  profile JSON; second `i` plays `power[i]`). Plus `kBuiltInProfiles`:
  `kCdaCrrMassProfile` (tarmac) and `kSurfaceCrrProfile` (off-road Crr; its
  doc comment records the forward-model validation). Pure/testable like
  `cpm_codec.dart`.
- `lib/profile_store.dart` — `ProfileStore` (`shared_preferences`): custom
  profiles (max 20) and the selected profile id; corrupt data falls back to
  the built-ins.
- `lib/profile_picker.dart` — the profile library bottom sheet: select,
  duplicate, edit/delete custom profiles (with undo; recorded rides have no
  Edit), new profile, and "Import CSV ride" at the end of My profiles.
- `lib/csv_power_import.dart` — pure `parseCsvPower`: detects delimiter and
  header (time/power/cadence names, or no header = time, power, cadence),
  parses seconds or `h:mm:ss`, filters a Dual record `slot`, averages rows
  per second, interpolates gaps, clamps, and returns a `PowerTrack` plus
  warnings. `lib/csv_import_dialog.dart` — `pickCsvFile` (`file_selector`,
  no extra permissions, 50 MB cap) and the import dialog (name, stats,
  device choice, cadence when the file has none); parsing runs in
  `Isolate.run`, injectable for tests.
- `lib/profile_editor_page.dart` — create/edit a custom profile: live chart,
  reorderable segments, segment dialog (ramp / coast toggles, clamped numeric
  fields), validation on save, discard confirmation.
- `lib/profile_player.dart` — `ProfilePlayerView` (a power-vs-time
  `CustomPaint` chart with a live playhead, progress, Run/Stop, a segment
  list, and the selected-profile card with a Change button). Stateless;
  playback state lives in `_EmulatorPageState`.
- `analysis/fit_cda.py` — offline Python fitter: reads a Zwift `.FIT` ride
  of a built-in profile and fits CdA / Crr / effective mass with
  uncertainty, significance of setup deltas, a power/speed timing check and
  optional plots (`analysis/README.md`). Its `PROFILE` table (used only by
  `--self-test`; fitting reads the FIT power) mirrors `kCdaCrrMassProfile`
  — update both together.
- `assets/icon/generate_icon.py` + `flutter_launcher_icons.yaml` — draw the
  PLACEHOLDER launcher icons and Play graphics and run
  `flutter_launcher_icons` (dev dependency) safely; never run that tool on
  its own (it corrupts `project.pbxproj`, see the yaml).
- `store/` — Play listing, privacy policy (`.md` + hosted `.html`, keep in
  sync), Data safety and content-rating answers, release checklist, and the
  store graphics. Update them when permissions or features change.

## Protocol invariants (do not break)
- CPM packet (`0x2A63`) is little-endian: uint16 flags (`0x0020` = crank data
  present) + sint16 power (W) + uint16 cumulative crank revs + uint16 last crank
  event time (units of 1/1024 s). Total 8 bytes.
- Cadence is NEVER sent as an RPM number. Receivers derive it from deltas:
  `rpm = ΔRev × 1024 × 60 / ΔTime`. Crank revs and event time must advance in
  lockstep with cadence, or recovered cadence will be wrong. Both fields wrap at
  65536 (event time wraps ~64 s); wrap handling is required.
- Cycling Power Feature (`0x2A65`) = `0x00000008` (bit 3, Crank Revolution Data
  Supported). Sensor Location (`0x2A5D`) = `5` (Left Crank). `0x2A5B` is CSC
  Measurement; versions before the multi-sensor change wrongly used it for
  Sensor Location.
- Characteristic UUIDs must be unique across all registered services: the
  single read handler only receives the characteristic UUID.
- Heart Rate Measurement (`0x2A37`): flags (bit 0 uint16 value, bit 1 contact
  detected, bit 2 contact supported, bit 4 RR present) + bpm + RR intervals in
  1/1024 s, at most 8 so the packet fits 20 bytes. 0 bpm = no contact, no RR.
  Body Sensor Location (`0x2A38`) = `1` (Chest).
- CSC Measurement (`0x2A5B`): flags (bit 0 wheel, bit 1 crank) + uint32
  cumulative wheel revs + uint16 wheel event time + uint16 crank revs + uint16
  crank event time, all times in 1/1024 s (CPS wheel data would use 1/2048 s).
  CSC Feature (`0x2A5C`) = `0x0003`. Its crank bytes must equal the CPM crank
  bytes for the same tick (one shared `CrankSimulator`).
- Central side (Dual record): decoders mirror the encoders' layouts and must
  ignore trailing bytes and return null (not throw) on truncated packets.
  Cadence/speed come from deltas with masking (16-bit crank revs/time,
  32-bit wheel revs, 16-bit wheel time); CPS wheel time is 1/2048 s, CSC
  1/1024 s. A repeated (revs, time) pair holds the last rate for 3 s, then
  0; a gap longer than one event-time wrap re-baselines. FTMS Indoor Bike
  Data bit 0 is inverted (speed present when CLEAR) and sends cadence
  directly (0.5 rpm).
- Advertising and Dual record never run at the same time (the app-bar
  action is disabled while advertising, and the screen covers the Start
  button), so the phone is never peripheral and central at once.
- Legacy advertising is 31 bytes: flags (3) + 16-bit UUID list (2 + 2 per
  service) + local name (2 + UTF-8 bytes). So the name fits 22 / 20 / 18 bytes
  with 1 / 2 / 3 services; `fitAdvertisedName` cuts it at a character
  boundary. Device Information is never advertised.

## Commands
- Install deps: `flutter pub get`
- Run on device: `flutter run`
- Analyze / lint: `flutter analyze`
- Format: `dart format lib/ test/`
- Tests: `flutter test`
- Analysis self-test: `cd analysis && .venv/bin/python fit_cda.py --self-test`
  (create the venv per `analysis/README.md`)
- Icons: `python3 assets/icon/generate_icon.py` (needs Pillow)
- Release: `flutter build apk --release` / `flutter build appbundle`
  (debug-signed unless `android/key.properties` exists)
- GitHub (https://github.com/vincentdavis/GOTTA.BIKE-BLE-Watts, public):
  `.github/workflows/ci.yml` checks every push to `main` / PR (format,
  analyze, test, APK build, analysis self-test; pins `FLUTTER_VERSION`, keep
  it in step with local Flutter). Releases are built LOCALLY, never on
  GitHub, so the upload key stays on this Mac: `tool/release.sh X.Y.Z
  [--dry-run]` (bash 3.2) checks a clean, pushed `main`, a higher
  version and that `pubspec.yaml` says `X.Y.Z+<versionCode>` (iOS reads
  it, so both platforms match), runs format/analyze/test, builds APK +
  AAB with versionCode =
  X*1e6 + Y*1e3 + Z, refuses debug signing, then tags `vX.Y.Z`, pushes the
  tag and runs `gh release create` with APK + AAB + SHA256SUMS. Don't add a
  tag-triggered release workflow (the script refuses to run if
  `.github/workflows/release.yml` exists).
- Mac download (outside the Mac App Store): after `tool/release.sh X.Y.Z`,
  check out `vX.Y.Z` and run `tool/release_macos.sh X.Y.Z [--dry-run]` on
  the Mac. It builds `flutter build macos --release`, re-signs with the
  Developer ID certificate + hardened runtime using
  `macos/Runner/DeveloperID.entitlements` (not the App Store
  `Release.entitlements`; keep the two sandbox sets equal), notarizes and
  staples the app and a DMG, and adds `gotta-bike-ble-watts-macos.dmg`
  (versionless name, so `releases/latest/download/...` works for the
  website) to that GitHub Release. Certificate and notary profile stay in
  the keychain, never on GitHub. Setup: `store/macos-direct-download.md`.

## Testing constraints
- BLE peripheral mode does NOT work in the iOS Simulator. A recent Android
  emulator (API 36 image, 2026-09) reports peripheral support and starts
  advertising on its virtual Bluetooth, which is enough to exercise the UI
  and the screen-off service, but testing with real centrals (Zwift, head
  units) needs a physical phone. Fastest correctness check: run
  `nRF Connect` on a second phone/PC, scan for "GOTTA.BIKE Watts", read
  `0x2A65`/`0x2A5D`, subscribe to `0x2A63`, watch the 8-byte packets (and
  `0x2A37` / `0x2A5B` when those sensors are on).
- On Android, `universal_ble` advertises the local name by temporarily
  renaming the phone's Bluetooth adapter; it restores the name when
  advertising stops. A crash while advertising can leave the phone renamed.
- iOS advertises standard 16-bit service UUIDs only in the FOREGROUND; a
  backgrounded iPhone is invisible to non-Apple centrals. Do not try to "fix"
  background discovery — it is an OS limitation, not a bug.
- Android requires chipset advertiser support; check
  `UniversalBlePeripheral.getCapabilities().supportsPeripheralMode` at runtime.
- A backgrounded / screen-off Flutter app is suspended by Android: the 500 ms
  notify timer and the BLE peripheral freeze, so the central (e.g. Zwift) drops
  the link after its supervision timeout. While advertising, the app always
  keeps the screen on as long as it is visible (`wakelock_plus`, via
  `KeepAwake`). With Settings › "Keep broadcasting with screen off" on,
  `BroadcastKeepAliveService` also runs and holds a partial wake lock, so
  broadcasting survives the power button or leaving the app; on the emulator
  the process then kept running (not frozen) with the screen off and after
  Home. Swiping the app away or
  finishing the activity stops the service (the broadcast lives in the
  activity's engine). Still to verify on a physical phone with Zwift.
- Dual record keeps the screen on while a sensor is connected or a recording
  runs, but has no screen-off mode: keep the app in front. Real sensors
  need the physical phone; the iOS Simulator has no Bluetooth.
- `universal_ble` gotchas seen in tests: its `UniversalBleStreamController`
  closes when the last listener cancels (get a fresh stream after
  cancelling); its commands go through a global queue; `disconnect` waits up
  to its timeout for an event (pass a short one). In widget tests BLE events
  land in microtasks after the pumped frame: pump twice.
- Do not replace the native service with `flutter_foreground_task` or any
  plugin that starts a second FlutterEngine: every plugin attaches to that
  engine too, and when it is destroyed `universal_ble` clears its
  process-wide GATT characteristic/subscriber caches, which silently breaks
  notifications for the main engine.
- Play Console: the `connectedDevice` foreground service needs the
  foreground-service declaration (App content) before release.
- iOS deployment target is 15.0 in `ios/Runner.xcodeproj/project.pbxproj`
  (Xcode 27 supports 15.0+; `universal_ble` via Swift Package Manager needs
  >= 13.1). Re-running `flutter create` resets it to 13.0 and breaks the iOS
  build — bump it back to 15.0.
- iOS bundle ID is `ble.watts.bike.gotta` (Android's applicationId is
  `ble.make.bike.gotta`; they are independent). `ios/Runner/Info.plist` sets
  `ITSAppUsesNonExemptEncryption = false` and has no background modes (iOS
  only advertises service UUIDs in the foreground anyway).
  `ios/Runner/PrivacyInfo.xcprivacy` (no tracking, no collected data,
  UserDefaults reason CA92.1) is in the Runner target's resources; update it
  if the app starts using other required-reason APIs or collecting data.

## Conventions
- Keep the codecs (`cpm_codec.dart`, `hr_codec.dart`, `csc_codec.dart`) pure
  and unit-testable; add tests there when changing encoding.
- BLE UUIDs are compared via `BleUuidParser.compareStrings` (centrals report
  128-bit lowercase UUIDs).
- If adding services (e.g. FTMS `0x1826`), mirror the existing split: a pure
  codec module + thin `universal_ble` glue in `cps_peripheral.dart`.
- `test/cps_peripheral_test.dart` drives the glue through a fake
  `UniversalBlePeripheralPlatform` (`UniversalBlePeripheral.setInstance`).
- Central tests use `test/fake_central_platform.dart`
  (`UniversalBle.setInstance`): push scan results, drops and notifications.
