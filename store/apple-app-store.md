# Release checklist: GOTTA.BIKE: BLE Watts on the Apple App Store

One App Store Connect record ships the app to **iPhone, iPad and Mac**
(universal purchase): the iOS app (`ios/`, iPhone + iPad) and the native
macOS app (`macos/`) share the bundle ID `ble.watts.bike.gotta`. Minimum OS:
**iOS 27, iPadOS 27, macOS 27**. Builds are archived and uploaded locally
with Xcode 27 or later (like Android, nothing is signed on GitHub).

The Mac download outside the App Store (Developer ID, notarized) is a
separate build with its own entitlements; it uses the same bundle ID. See
`macos-direct-download.md`.

Rules change: re-check anything marked **verify** in App Store Connect
before you rely on it.

## 1. What the project already sets

| Setting | iOS / iPadOS | macOS |
|---|---|---|
| Deployment target | `IPHONEOS_DEPLOYMENT_TARGET = 27.0` | `MACOSX_DEPLOYMENT_TARGET = 27.0` |
| Devices | `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone + iPad), all iPad orientations, so Split View / Stage Manager work | Resizable window, min 360x600 pt, opens at 520x860 |
| Bluetooth text | `NSBluetoothAlwaysUsageDescription` + `NSBluetoothPeripheralUsageDescription` | same keys, same text |
| Sandbox / capabilities | (iOS apps are always sandboxed) | `Release.entitlements`: App Sandbox, Bluetooth (`com.apple.security.device.bluetooth`), user-selected files read/write (CSV import and "Save CSV as…") |
| Export compliance | `ITSAppUsesNonExemptEncryption = false` | same |
| Privacy manifest | `ios/Runner/PrivacyInfo.xcprivacy` | `macos/Runner/PrivacyInfo.xcprivacy` (same content: no tracking, no data collected, UserDefaults reason CA92.1) |
| Category | set in App Store Connect | `LSApplicationCategoryType = public.app-category.healthcare-fitness` |
| Other | no background modes (iOS only advertises service UUIDs in the foreground) | `NSAppSleepDisabled` (no App Nap while the window is hidden) |

The UI centres a column at most 720 pt wide (`lib/responsive.dart`), so it
reads well on every iPad size and in any Mac window.

## 2. Accounts and the App Store Connect record

- [ ] Apple Developer Program membership (individual or organization).
- [ ] In Certificates, Identifiers & Profiles, register the explicit App ID
      `ble.watts.bike.gotta` with platforms iOS and macOS. No extra
      capabilities are needed on the App ID (Bluetooth is an entitlement
      only).
- [ ] In App Store Connect, create **one** app: platforms iOS and macOS,
      bundle ID `ble.watts.bike.gotta`, SKU of your choice, primary
      language English. Both platforms then share the name, price and
      purchase (universal purchase).
- [ ] Pricing and Availability › **iPhone and iPad Apps on Apple Silicon
      Macs**: leave the iPad app unavailable on Mac. The native Mac app
      replaces it (**verify**: App Store Connect hides the option once a macOS
      build exists).

## 3. Signing (once, in Xcode)

- [ ] `open ios/Runner.xcworkspace`, Runner target › Signing & Capabilities:
      tick **Automatically manage signing** and pick your Team for Debug,
      Release and Profile.
- [ ] `open macos/Runner.xcworkspace`, same for the Runner target. Check that
      the capabilities list shows App Sandbox with **Bluetooth** and **User
      Selected File: Read/Write** ticked (they come from the entitlements
      files; don't add others).
- [ ] Xcode writes `DEVELOPMENT_TEAM` into both `project.pbxproj` files.
      Committing that line is fine (a team ID is not secret).

## 4. Version

`pubspec.yaml` `version: X.Y.Z+N` (N = X*1e6 + Y*1e3 + Z) drives
`CFBundleShortVersionString` / `CFBundleVersion` on iOS and macOS, the same
as Android's versionName / versionCode. Bump it before each upload; App Store
Connect refuses a build number it has seen for that platform.

## 5. Build and upload

```bash
flutter clean && flutter pub get
flutter analyze && flutter test

# iPhone + iPad
flutter build ipa --release
open build/ios/archive/Runner.xcarchive     # Organizer › Distribute App › App Store Connect

# Mac
flutter build macos --release
open macos/Runner.xcworkspace               # Product › Archive, then Distribute App › App Store Connect
```

(`flutter build ipa` can also upload directly with
`--export-method app-store` and `xcrun altool`/Transporter.)

## 6. Test before review

- [ ] TestFlight on a physical **iPhone** and **iPad**: nRF Connect on a
      second device sees "GOTTA.BIKE Watts", reads `0x2A65` / `0x2A5D` and
      gets `0x2A63` notifications; Zwift pairs power and cadence; Dual
      record connects to two sensors and shares a CSV (on iPad the share
      popover must anchor to the button).
- [ ] TestFlight on a **Mac** (macOS 27): same checks; resize the window
      from narrow to full screen; "Save CSV as…" writes where you choose;
      Import CSV ride opens a file; cover or minimise the window for a few
      minutes while Zwift is paired and confirm data keeps flowing.
- [ ] The Bluetooth permission prompt appears on first Start / scan, and
      turning Bluetooth access off in Settings / System Settings › Privacy
      shows the app's status message instead of crashing.

## 7. Store listing (per platform)

Reuse the text in `listing.md`. Apple specifics:

- [ ] Name (30 chars) `GOTTA.BIKE: BLE Watts`; subtitle (30 chars); promo
      text; description; keywords (100 chars, comma-separated); support URL;
      marketing URL (the website); privacy policy URL (hosted
      `privacy-policy.html`).
- [ ] Category: Health & Fitness (secondary: Sports or Utilities).
- [ ] Screenshots (**verify** current sizes in App Store Connect): iPhone
      6.9" (1320x2868 portrait), iPad 13" (2064x2752 portrait), Mac
      (2880x1800, 16:10). Larger sets scale down to the smaller devices.
- [ ] App Privacy: **Data Not Collected** (matches the privacy manifests and
      `data-safety.md`).
- [ ] Age rating questionnaire: all "None" (see `content-rating.md`).
- [ ] Copyright: `2026 Vincent Davis`.

## 8. App Review notes

Reviewers have no cycling sensor. Paste something like:

> The app turns this device into a Bluetooth LE cycling sensor (Cycling
> Power 0x1818, Heart Rate 0x180D, Speed & Cadence 0x1816). Tap "Start
> advertising"; any BLE scanner on a second device (for example nRF Connect)
> sees "GOTTA.BIKE Watts" and receives power/cadence notifications. "Dual
> record" (top-right icon) connects to two real sensors and records them to
> a CSV. No account, no network access, no data leaves the device.

- [ ] Attach a short screen recording of a scanner receiving data (Apple
      often asks for one for hardware-accessory apps).

## Known platform limits (not bugs)

- iOS / iPadOS advertise standard service UUIDs only while the app is in the
  foreground; a backgrounded iPhone or iPad is invisible to non-Apple
  centrals. The app keeps the screen on while advertising.
- macOS has no screen-off mode switch (that is Android only); the Mac keeps
  advertising while the window is hidden because App Nap is disabled.
- The Bluetooth MAC address is chosen by the OS and can't be set.
