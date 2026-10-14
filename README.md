# GOTTA.BIKE: BLE Watts

[![CI](https://github.com/vincentdavis/GOTTA.BIKE-BLE-Watts/actions/workflows/ci.yml/badge.svg)](https://github.com/vincentdavis/GOTTA.BIKE-BLE-Watts/actions/workflows/ci.yml)

A Flutter app that turns a phone into a **Bluetooth LE cycling sensor
emulator**. It advertises standard BLE sensor services, so bike computers,
cycling apps (for example Zwift) and BLE tools (for example nRF Connect) can
pair with it like a real sensor and receive the values you choose.

It is a **sensor**, not a smart trainer: there is no FTMS / ERG resistance
control. All values are simulated.

<!-- Screenshot placeholder: add store screenshots here, e.g.
![Main screen](store/screenshots/main.png) -->

## Features

- **Cycling Power** (`0x1818`): instantaneous power plus crank revolution
  data, so receivers derive cadence the same way they do with a real power
  meter. Updates twice per second.
- **Heart Rate** (`0x180D`) and **Speed & Cadence** (`0x1816`), which you
  switch on in Settings.
- **Device Information** (`0x180A`): editable advertised name, manufacturer
  and model.
- **Manual mode**: power (0–800 W) and cadence (0–150 rpm) steppers and up to
  5 one-tap presets.
- **Test-profile mode**: scripted, timed power profiles (steady steps, ramps,
  coasts) with a live chart. Pick a built-in profile or build your own in the
  editor. Built-ins:
  - **CdA · Crr · Mass estimation** (10 min, tarmac)
  - **Surface Crr (off-road)** (9 min, gravel or dirt)
- Keeps the screen on while broadcasting. Optionally (Android), it also
  keeps broadcasting if the screen turns off or you switch apps, through a
  foreground service with a persistent notification and a Stop button.

## CdA / Crr / mass analysis

Play the estimation profile solo on a flat Zwift road, export the ride's
`.FIT`, and fit it:

```bash
cd analysis && python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python fit_cda.py --self-test
python fit_cda.py baseline.fit aero_wheels.fit --mass 80 --plot
```

See [`analysis/README.md`](analysis/README.md) for how the fit works, how to
read the uncertainty and significance columns and the plots, and its limits.
In Zwift only frames and wheels change performance, so compare setups as
deltas.

## Build and run

Requires Flutter (see `pubspec.yaml` for the SDK constraint). Test with real
centrals on a **physical** Android or iOS device: BLE peripheral mode doesn't
work in the iOS Simulator, and a recent Android emulator can advertise on its
virtual Bluetooth (enough to try the UI) but can't reach Zwift or a bike
computer.

```bash
flutter pub get
flutter run
```

Other commands:

```bash
flutter analyze
flutter test
flutter build apk --release
flutter build appbundle
```

Release builds are signed with `android/key.properties` when it exists and
fall back to the debug key otherwise (fine for sideloading, rejected by Play).
See [`store/release-checklist.md`](store/release-checklist.md) for the upload
key, the App Bundle, and the Play Console steps.

**Releases:** `tool/release.sh 1.0.0` builds a signed APK and App Bundle on
this machine, tags `v1.0.0`, and publishes them on the
[Releases](https://github.com/vincentdavis/GOTTA.BIKE-BLE-Watts/releases)
page. To install on a phone, download the `.apk` from there. Every push to
`main` also runs the tests and a build on GitHub (CI). Details:
[`store/release-checklist.md`](store/release-checklist.md#releases-on-github).

The launcher icons and Play graphics use a **placeholder** mark (a lightning
bolt between broadcast arcs). `python3 assets/icon/generate_icon.py`
regenerates them; see that script to swap in the real GOTTA.BIKE artwork.

## Testing notes

- Fastest correctness check: on a second device, open **nRF Connect**, scan
  for the advertised name (default **GOTTA.BIKE Watts**), read the Cycling
  Power Feature and Sensor Location characteristics, and subscribe to Cycling
  Power Measurement.
- Android needs a chipset that supports BLE advertising (peripheral mode).
  The app tells you if it doesn't.
- Android suspends a backgrounded app, so the app keeps the screen on while
  broadcasting. Turn on screen-off broadcasting in Settings to keep going if
  the screen turns off or you switch apps.
- iOS advertises standard service UUIDs only while the app is in the
  foreground.

More architecture and protocol details are in [`CLAUDE.md`](CLAUDE.md).

## Privacy

No account, no ads, no analytics, and no network use in release builds.
Presets, profiles and settings stay on the device. The advertised device name
is broadcast openly over Bluetooth, so keep personal information out of it.
Full policy: [`store/privacy-policy.md`](store/privacy-policy.md).

## Responsible use and trademarks

The app creates simulated sensor data for testing. Don't use it to upload or
submit rides, races or leaderboard efforts as if they were real, and follow
the rules of every platform you connect it to.

GOTTA.BIKE: BLE Watts is an independent app. It is not affiliated with,
endorsed by or sponsored by Zwift, Garmin, Wahoo, Nordic Semiconductor or the
Bluetooth SIG. The Bluetooth® word mark and logos are registered trademarks
owned by Bluetooth SIG, Inc.

## License

MIT. See [`LICENSE`](LICENSE).
