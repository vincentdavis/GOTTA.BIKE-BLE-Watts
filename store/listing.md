# Google Play store listing: GOTTA.BIKE: BLE Watts

Draft store listing for the first Play release (`version: 1.0.0+1`,
applicationId `ble.make.bike.gotta`). Paste the text blocks below into
**Play Console > Grow users > Store presence > Main store listing**.

- Every text block sits between `BEGIN`/`END` markers. The character counts
  in the table were computed by a script (see
  [Re-checking the counts](#re-checking-the-counts)), not by hand.
- Values in `[BRACKETS]` are placeholders the owner has to fill in.
- Some features are being added in this same release by other work streams.
  Before you submit, check them against
  [Features to confirm before submitting](#features-to-confirm-before-submitting).

## Summary

| Field | Value | Play limit | Count |
|---|---|---|---|
| App name | `GOTTA.BIKE: BLE Watts` | 30 | 21 |
| Short description (recommended) | see below | 80 | 78 |
| Short description, alternate A | see below | 80 | 72 |
| Short description, alternate B | see below | 80 | 75 |
| Short description, alternate C | see below | 80 | 72 |
| Full description | see below | 4000 | 3629 (3586 without its 43 line breaks) |
| Category | **Tools** (recommended) | n/a | n/a |
| Tags | up to 5 from Google's list | 5 | n/a |
| Contact email | `[CONTACT EMAIL]` (required, shown publicly) | n/a | n/a |
| Website | `[WEBSITE URL]`, probably `https://gotta.bike` (owner to confirm) | n/a | n/a |
| Privacy policy URL | `[PRIVACY POLICY URL]`, where `store/privacy-policy.html` is hosted | n/a | n/a |

The limits come from Play Console Help: app name 30, short description 80,
full description 4000 characters
([Create and set up your app](https://support.google.com/googleplay/android-developer/answer/9859152)).
All counts include line breaks, one character per `\n`. The text uses only
Basic Multilingual Plane characters, so Unicode code points and UTF-16 code
units give the same count.

## App name

<!-- BEGIN app-name -->
```text
GOTTA.BIKE: BLE Watts
```
<!-- END app-name -->

This matches `android:label` in `android/app/src/main/AndroidManifest.xml` and
the in-app title in `lib/main.dart`. The Metadata policy says to avoid all caps
"unless it is part of your brand name". `GOTTA.BIKE` is the brand and `BLE` is
an acronym, so the title is fine. It has no emoji and no repeated special
characters
([Metadata policy](https://support.google.com/googleplay/android-developer/answer/9898842)).

## Short description

Recommended. It stays accurate whichever of the pending sensors ship:

<!-- BEGIN short-description -->
```text
Turn your phone into a Bluetooth LE cycling sensor to test apps and head units
```
<!-- END short-description -->

Alternate A. Power meter only:

<!-- BEGIN short-description-alt-a -->
```text
Emulate a Bluetooth power meter to test bike computers and cycling apps.
```
<!-- END short-description-alt-a -->

Alternate B. Use it only if Heart Rate **and** Speed & Cadence ship:

<!-- BEGIN short-description-alt-b -->
```text
Bluetooth LE cycling sensor emulator: power, cadence, heart rate and speed.
```
<!-- END short-description-alt-b -->

Alternate C:

<!-- BEGIN short-description-alt-c -->
```text
Simulated BLE power and cadence for testing cycling apps and head units.
```
<!-- END short-description-alt-c -->

## Full description

This is plain text. The bullets are the `•` character. Paste it as is.

<!-- BEGIN full-description -->
```text
GOTTA.BIKE: BLE Watts turns an Android phone into a Bluetooth LE cycling sensor emulator. It advertises standard Bluetooth LE sensor services, so cycling apps, bike computers and BLE tools can pair with it like a real sensor and receive the values you choose.

It is built for developers, testers and enthusiasts who want to check head units, cycling apps and indoor-training setups with repeatable input, without pedalling. All values are simulated: the app does not measure your power, cadence, heart rate or speed.

Sensors it emulates
• Cycling Power (standard service 0x1818): instantaneous power plus crank revolution data, so receivers work out cadence the same way they do with a crank-based power meter
• Heart Rate (standard service 0x180D)
• Cycling Speed and Cadence (standard service 0x1816)
• Device Information (0x180A) with an editable manufacturer name and model number
• New values are sent twice per second

Manual mode
• Set power (0 to 800 W in 5 W steps) and cadence (0 to 150 rpm in 1 rpm steps) with large plus and minus buttons, and press and hold to change values quickly
• Save up to 5 presets (name, power and cadence) and switch levels with one tap

Test-profile mode
• Play scripted, timed power profiles made of steady steps, ramps and coasts, identical on every run
• Watch a live power-vs-time chart with a playhead, progress and the active step highlighted
• Choose a built-in profile or build your own in the profile editor
• CdA · Crr · Mass estimation profile (10 minutes): a steady-power ladder, a hard acceleration and two coast-downs, designed to help estimate the drag area (CdA), rolling resistance (Crr) and effective mass that a virtual-riding app assigns to an equipment setup
• Surface Crr profile for comparing rolling resistance on off-road surfaces

Identity and control
• Set the advertised device name, the manufacturer name and the model number
• See a live count of connected subscribers, with one button to start and stop
• By default the screen stays on while broadcasting, so Android doesn't pause the app
• Optional: keep broadcasting with the screen off, with a persistent notification shown while it runs

Privacy
• No account, no ads, no analytics
• No personal data is collected or shared. Presets, profiles and settings stay on your phone.
• Anything you type into the device name is broadcast openly over Bluetooth, so leave personal information out of it

Requirements
• Android 7.0 or newer with Bluetooth LE
• Your phone's Bluetooth hardware must support BLE advertising (peripheral mode). The app tells you if it doesn't.
• The app follows the standard Bluetooth LE sensor profiles, so it is meant for any app or bike computer that accepts standard BLE sensors. Cycling Power output has been tested with Zwift and nRF Connect. Whether it works depends on the receiving app or device.
• It is a sensor emulator, not a smart trainer: it has no resistance or ERG control.

Responsible use
This app creates simulated sensor data for testing. Don't use it to record, upload or submit rides, races, results or leaderboard efforts as if they were real, and follow the rules of every platform you connect it to. Run test profiles solo, outside organized events, and keep test activities off public leaderboards and training logs.

Trademarks
GOTTA.BIKE: BLE Watts is an independent app. It is not affiliated with, endorsed by or sponsored by Zwift, Garmin, Wahoo, Nordic Semiconductor or the Bluetooth SIG. The Bluetooth® word mark and logos are registered trademarks owned by Bluetooth SIG, Inc. All other product names and trademarks belong to their respective owners.
```
<!-- END full-description -->

### Where each claim comes from

| Claim | Source in the repo |
|---|---|
| CPS `0x1818`, power + crank revolution data, cadence derived by receivers | `lib/cps_peripheral.dart`, `lib/cpm_codec.dart` |
| Device Information `0x180A` with Manufacturer (`0x2A29`) and Model (`0x2A24`) | `lib/cps_peripheral.dart` |
| "twice per second" | `kNotifyInterval = 500 ms` in `lib/main.dart` |
| Power 0 to 800 W in 5 W steps, cadence 0 to 150 rpm in 1 rpm steps, press and hold | `_AdjustControl` in `lib/main.dart` |
| Up to 5 presets | `kMaxPresets = 5` in `lib/presets.dart` |
| Chart, playhead, progress, active step | `lib/profile_player.dart` |
| CdA · Crr · Mass profile: 10 minutes, ladder, acceleration, two coast-downs | `kCdaCrrMassProfile` (600 s) in `lib/power_profile.dart` |
| Editable name, manufacturer, model | `lib/device_identity.dart`, `lib/settings_page.dart` |
| Live subscriber count, start/stop | `lib/main.dart` |
| Screen stays on while broadcasting, so Android doesn't pause the app | `WakelockPlus.enable()` in `_toggleAdvertising` (`lib/main.dart`); `CLAUDE.md` testing constraints |
| Tells you if peripheral mode is unsupported | `isSupported()` in `lib/cps_peripheral.dart`, plus the status text in `lib/main.dart` |
| Android 7.0 or newer, Bluetooth LE required | `minSdkVersion 24` in the merged release manifest; `uses-feature android.hardware.bluetooth_le required="true"` |
| No analytics, ads or network | `pubspec.lock` has no analytics, ads or crash SDK; the merged release manifest has no `INTERNET` permission (see `store/data-safety.md`) |
| Tested with Zwift and nRF Connect | the owner's own device testing notes (Galaxy A16). **Re-test on the release build.** |
| Not a smart trainer | `CLAUDE.md` ("no FTMS / ERG resistance control") |

## Features to confirm before submitting

Other work streams are adding these features in this release. Before you
submit, confirm each one is on `main` and works on a physical phone. If a
feature did not ship, delete its text:

| Feature | Lines to delete from the full description if it did not ship |
|---|---|
| Heart Rate sensor (`0x180D`) | `• Heart Rate (standard service 0x180D)`, and `heart rate` in the second paragraph |
| Speed & Cadence sensor (`0x1816`) | `• Cycling Speed and Cadence (standard service 0x1816)`, and `or speed` in the second paragraph |
| Profile picker and in-app profile editor | `• Choose a built-in profile or build your own in the profile editor` |
| Off-road "Surface Crr" profile | `• Surface Crr profile for comparing rolling resistance on off-road surfaces` |
| Optional screen-off broadcasting (foreground service) | `• Optional: keep broadcasting with the screen off, ...` |

If you use alternate B, both HR and CSC must have shipped. After any edit,
re-run the count script. Update `store/privacy-policy.md`,
`store/privacy-policy.html` and `store/release-checklist.md` to match.

## Category

**Recommendation: Tools.** Play lists both "Tools" and "Health and Fitness"
as app categories
([Choose a category and tags](https://support.google.com/googleplay/android-developer/answer/9859673)).
Reasons for Tools:

1. **The app is a test instrument, not a fitness tracker.** It measures and
   records nothing about the user. It generates simulated sensor data for
   developers, testers and enthusiasts. Tools matches what it does, and
   people who browse Health and Fitness expect workout tracking.
2. **It matches the Health apps declaration.** Every app has to complete
   the Health apps declaration. Its "Activity and Fitness" category covers apps
   that "monitor and record physical activities". This app does neither, so
   the correct answer is "My app doesn't provide any health features"
   ([Health apps declaration](https://support.google.com/googleplay/android-developer/answer/14738291)).
   Listing it under Health and Fitness while declaring no health features
   could look inconsistent to a reviewer. That risk is our judgement, not a
   documented rule.
3. **It lowers the risk of misuse.** A Health and Fitness listing would put
   a "power and heart-rate generator" in front of people looking for workout
   apps, which is exactly the audience the responsible-use note warns about.

Trade-off: Health and Fitness might get more organic discovery from
cyclists. If you want that audience, reach it through tags and the
description keywords, not the category.

## Tags

Play allows at most **five** tags. You pick them from Google's predefined
list under **Grow users > Store presence > Store settings > App category >
Manage tags**
([source](https://support.google.com/googleplay/android-developer/answer/9859673)).
The list is only visible inside Play Console, so we could not check the
exact tag names. Look for tags close to these, in order of preference:

1. Bluetooth / connectivity
2. Developer tools / utilities
3. Cycling
4. Sports and fitness devices, or wearables
5. Simulation / testing

Choose only tags that are "most obviously relevant". Skip any tag that
suggests workout tracking.

## Keywords

Play has no keyword field. These terms already appear in the description
naturally, and none of them is repeated just for search. The Metadata policy
prohibits "repetitive or unrelated keywords".

`Bluetooth LE`, `BLE`, `cycling sensor`, `power meter`, `cycling power`,
`cadence`, `heart rate`, `speed and cadence`, `sensor emulator`,
`bike computer`, `head unit`, `indoor training`, `CdA`, `Crr`,
`rolling resistance`, `test profile`, `nRF Connect`.

## Contact details and URLs

Store listing contact details are shown publicly on the listing. An email
address is required. Phone and website are optional
([developer account information](https://support.google.com/googleplay/android-developer/answer/13634081)).

- Email: `[CONTACT EMAIL]`. Use a role address you are happy to publish.
- Website: `[WEBSITE URL]`. The brand is GOTTA.BIKE; confirm that
  `https://gotta.bike` is the right site and that it is live.
- Privacy policy: `[PRIVACY POLICY URL]`. Host `store/privacy-policy.html` on
  a public, non-geofenced URL (no PDF), for example GitHub Pages. See
  `store/release-checklist.md`.

## Other store settings

- App or game: **App**. Free or paid: **Free**.
- Contains ads: **No**. In-app purchases: **none**.
- Default language: English (United States), en-US.

## Notes and cautions

- **Third-party names.** The description names Zwift and nRF Connect once,
  as factual compatibility information, and the trademark paragraph
  disclaims any affiliation. Keep third-party names out of the title, the
  short description, the icon and the screenshots. Screenshots should show
  only this app's UI. If a reviewer or rights holder objects, replace the
  "tested with" sentence with: `Cycling Power output has been tested with
  popular cycling apps and BLE debugging tools.`
- **Bluetooth word mark.** The listing uses "Bluetooth" descriptively and
  carries the standard Bluetooth SIG attribution. Before you use the
  Bluetooth logo or claim certification anywhere, check the Bluetooth SIG
  trademark and qualification rules.
- **No health or performance claims.** The description says outright that
  all values are simulated. Keep it that way. Don't describe the heart-rate
  output as a heart-rate monitor.
- **No ranking or promotional claims.** Avoid "best", "#1", prices or
  "free download" in the title and descriptions
  ([Metadata policy](https://support.google.com/googleplay/android-developer/answer/9898842)).
- **Companion analysis script.** `analysis/fit_cda.py` is left out of the
  listing because the repository may not be public. If you publish it, you
  can add a line that links to it.

## Re-checking the counts

Run this from the repo root after any edit. It prints the length of every
marked block:

```bash
python3 - <<'EOF'
import pathlib, re
doc = pathlib.Path("store/listing.md").read_text(encoding="utf-8")
limits = {"app-name": 30, "full-description": 4000}
pat = r"<!-- BEGIN (\S+) -->\n```text\n(.*?)\n```\n<!-- END \1 -->"
for name, body in re.findall(pat, doc, re.S):
    limit = limits.get(name, 80)
    units = len(body.encode("utf-16-le")) // 2
    status = "OK" if max(len(body), units) <= limit else "TOO LONG"
    print(f"{name}: {len(body)} chars (utf-16 units {units}) / {limit} {status}")
EOF
```

## Sources

- Create and set up your app (character limits):
  https://support.google.com/googleplay/android-developer/answer/9859152
- Metadata policy: https://support.google.com/googleplay/android-developer/answer/9898842
- Choose a category and tags: https://support.google.com/googleplay/android-developer/answer/9859673
- Health apps declaration: https://support.google.com/googleplay/android-developer/answer/14738291
- Developer account and contact information:
  https://support.google.com/googleplay/android-developer/answer/13634081
- Preview assets (icon, feature graphic, screenshots):
  https://support.google.com/googleplay/android-developer/answer/9866151
