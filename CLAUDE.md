# CLAUDE.md

## Project
Flutter app that turns a phone into a BLE **peripheral** emulating a standard
Cycling Power Service (CPS, `0x1818`) sensor — it broadcasts instantaneous power
and cadence to head units, Zwift, Garmin/Wahoo apps, and nRF Connect. It is a
*sensor*, not a controllable trainer: no FTMS / ERG resistance control.

## Stack
- Flutter (Dart >=3.1.3, Flutter >=3.3.0)
- BLE: `universal_ble` ^2.0.4 — peripheral / GATT-server + advertising
- `wakelock_plus` (keep screen on while advertising); `shared_preferences`
  (persist user presets)
- Material 3, dark theme. No state-management package; plain `StatefulWidget`.

## Layout
- `lib/cpm_codec.dart` — pure-Dart protocol core. `CrankSimulator` turns a target
  cadence into honest crank counters; `CpmCodec` packs the 8-byte `0x2A63` packet.
  Keep this free of any `universal_ble` imports so the BLE library can be swapped
  without touching protocol logic.
- `lib/cps_peripheral.dart` — `universal_ble` glue: defines the CPS GATT service
  plus a Device Information Service (`0x180A`), read handlers for Feature
  (`0x2A65`) / Sensor Location (`0x2A5B`) / Manufacturer (`0x2A29`) / Model
  (`0x2A24`), advertising under the editable device name, and the notify push on
  `0x2A63`.
- `lib/main.dart` — UI with a Manual / Test-profile mode switch. Manual: +/-
  stepper controls for power (step 5 W) and cadence (step 1 rpm) plus preset
  chips. Test-profile: plays the `PowerProfile` selected in the profile
  library (picker locked while a profile runs). Also start/stop
  advertising and a live subscriber count. A 500 ms timer (`_onTick`) pushes a
  measurement each tick, driven by the running profile if any, else the manual
  values.
- `lib/presets.dart` — pure `Preset` (power, cadence) model + `PresetStore`
  (`shared_preferences` persistence, max 5, sensible defaults). Keep the model
  pure/testable like `cpm_codec.dart`.
- `lib/settings_page.dart` — Settings screen: edit the device identity (name,
  manufacturer, model) and add/edit/delete the presets.
- `lib/device_identity.dart` — pure `DeviceIdentity` (advertised name +
  Manufacturer/Model for the DIS) + `DeviceIdentityStore` (`shared_preferences`).
  The MAC address is OS-assigned and not settable.
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

## Protocol invariants (do not break)
- CPM packet (`0x2A63`) is little-endian: uint16 flags (`0x0020` = crank data
  present) + sint16 power (W) + uint16 cumulative crank revs + uint16 last crank
  event time (units of 1/1024 s). Total 8 bytes.
- Cadence is NEVER sent as an RPM number. Receivers derive it from deltas:
  `rpm = ΔRev × 1024 × 60 / ΔTime`. Crank revs and event time must advance in
  lockstep with cadence, or recovered cadence will be wrong. Both fields wrap at
  65536 (event time wraps ~64 s); wrap handling is required.
- Cycling Power Feature (`0x2A65`) = `0x00000008` (bit 3, Crank Revolution Data
  Supported). Sensor Location (`0x2A5B`) = `5` (Left Crank).

## Commands
- Install deps: `flutter pub get`
- Run on device: `flutter run`
- Analyze / lint: `flutter analyze`
- Format: `dart format lib/`
- Tests: `flutter test`

## Testing constraints
- BLE peripheral mode does NOT work in the iOS Simulator or Android emulator.
  All BLE testing requires a physical device. Fastest correctness check: run
  `nRF Connect` on a second phone/PC, scan for "GOTTA.BIKE Watts", read
  `0x2A65`/`0x2A5B`, subscribe to `0x2A63`, watch the 8-byte packets.
- iOS advertises standard 16-bit service UUIDs only in the FOREGROUND; a
  backgrounded iPhone is invisible to non-Apple centrals. Do not try to "fix"
  background discovery — it is an OS limitation, not a bug.
- Android requires chipset advertiser support; check
  `UniversalBlePeripheral.getCapabilities().supportsPeripheralMode` at runtime.
- A backgrounded / screen-off Flutter app is suspended by Android: the 500 ms
  notify timer and the BLE peripheral freeze, so the central (e.g. Zwift) drops
  the link after its supervision timeout. The app holds a wakelock
  (`wakelock_plus`, enabled in `_toggleAdvertising` while advertising) to keep
  the screen on and the process foregrounded. True screen-off operation would
  require an Android foreground service (not implemented).
- iOS deployment target must be >= 13.1 (`universal_ble` is resolved via Swift
  Package Manager and requires it). This project pins 14.0 in
  `ios/Runner.xcodeproj/project.pbxproj`. Re-running `flutter create` resets it
  to 13.0 and breaks the iOS build with a "minimum platform version" error —
  bump it back to 14.0.

## Conventions
- Keep `cpm_codec.dart` pure and unit-testable; add tests there when changing
  encoding.
- BLE UUIDs are compared via `BleUuidParser.compareStrings` (centrals report
  128-bit lowercase UUIDs).
- If adding services (e.g. FTMS `0x1826`, Heart Rate `0x180D`), mirror the
  existing split: a pure codec module + thin `universal_ble` glue.
