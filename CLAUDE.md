# CLAUDE.md

## Project
Flutter app that turns a phone into a BLE **peripheral** emulating a standard
Cycling Power Service (CPS, `0x1818`) sensor — it broadcasts instantaneous power
and cadence to head units, Zwift, Garmin/Wahoo apps, and nRF Connect. It can
also emulate a Heart Rate (`0x180D`) and a Cycling Speed and Cadence (`0x1816`)
sensor (Settings › Sensors; at least one service is always on). It is a
*sensor*, not a controllable trainer: no FTMS / ERG resistance control.

## Stack
- Flutter (Dart >=3.1.3, Flutter >=3.3.0)
- BLE: `universal_ble` ^2.0.4 — peripheral / GATT-server + advertising
- `wakelock_plus` (keep screen on while advertising); `shared_preferences`
  (persist presets, device identity, profiles, the sensor selection and the
  screen-off setting)
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
  profile runs); heart rate and speed keep their manual values. Also
  start/stop advertising and a live subscriber count. A 500 ms timer
  (`_onTick`) pushes a measurement each tick, driven by the running profile if
  any, else the manual values.
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
- `lib/device_identity.dart` — pure `DeviceIdentity` (advertised name +
  Manufacturer/Model for the DIS) + `DeviceIdentityStore` (`shared_preferences`),
  plus the advertisement name budget (`advertisedNameBudget`,
  `fitAdvertisedName`). The MAC address is OS-assigned and not settable.
- `lib/limits.dart` — pure shared bounds (`kPowerMax`, `kCadenceMax`);
  `presets.dart` re-exports it. Pure files must import this, not
  `presets.dart` (which pulls in `shared_preferences`).
- `lib/power_profile.dart` — pure `PowerProfile` / `ProfileSegment` model
  (timed power/cadence segments, ramps, coasts; `sampleAt(t)`; stable ids;
  built-in vs custom; JSON with clamping; `validate()`) + `kBuiltInProfiles`:
  `kCdaCrrMassProfile` (tarmac) and `kSurfaceCrrProfile` (off-road Crr; its
  doc comment records the forward-model validation). Pure/testable like
  `cpm_codec.dart`.
- `lib/profile_store.dart` — `ProfileStore` (`shared_preferences`): custom
  profiles (max 20) and the selected profile id; corrupt data falls back to
  the built-ins.
- `lib/profile_picker.dart` — the profile library bottom sheet: select,
  duplicate, edit/delete custom profiles (with undo), new profile.
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
  analyze, test, APK build, analysis self-test). `release.yml` runs on a
  `vX.Y.Z` tag: version from the tag (versionCode = X*1e6 + Y*1e3 + Z),
  signed with the upload key from repo secrets `ANDROID_KEYSTORE_BASE64` /
  `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD`,
  fails if debug-signed, publishes APK + AAB + SHA256SUMS. Both pin
  `FLUTTER_VERSION`; keep it in step with local Flutter.

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
- Do not replace the native service with `flutter_foreground_task` or any
  plugin that starts a second FlutterEngine: every plugin attaches to that
  engine too, and when it is destroyed `universal_ble` clears its
  process-wide GATT characteristic/subscriber caches, which silently breaks
  notifications for the main engine.
- Play Console: the `connectedDevice` foreground service needs the
  foreground-service declaration (App content) before release.
- iOS deployment target must be >= 13.1 (`universal_ble` is resolved via Swift
  Package Manager and requires it). This project pins 14.0 in
  `ios/Runner.xcodeproj/project.pbxproj`. Re-running `flutter create` resets it
  to 13.0 and breaks the iOS build with a "minimum platform version" error —
  bump it back to 14.0.

## Conventions
- Keep the codecs (`cpm_codec.dart`, `hr_codec.dart`, `csc_codec.dart`) pure
  and unit-testable; add tests there when changing encoding.
- BLE UUIDs are compared via `BleUuidParser.compareStrings` (centrals report
  128-bit lowercase UUIDs).
- If adding services (e.g. FTMS `0x1826`), mirror the existing split: a pure
  codec module + thin `universal_ble` glue in `cps_peripheral.dart`.
- `test/cps_peripheral_test.dart` drives the glue through a fake
  `UniversalBlePeripheralPlatform` (`UniversalBlePeripheral.setInstance`).
