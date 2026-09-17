# Release checklist: GOTTA.BIKE: BLE Watts on Google Play

Work through these steps in order. Policy facts were checked against Google's
documentation on 2026-09-16 (sources at the end). Rules change, so re-check
any step marked **verify** before you rely on it.

Companion documents in this folder:

| File | Used in step |
|---|---|
| `listing.md` | 8 (store listing text, category, contact details) |
| `privacy-policy.html` / `.md` | 9 (host it, then paste the URL) |
| `data-safety.md` | 9 (Data safety form answers) |
| `content-rating.md` | 9 (IARC questionnaire answers) |
| `graphics/icon-512.png`, `graphics/feature-graphic-1024x500.png` | 8 (graphics) |

## 1. Confirm what ships

- [x] All feature branches are merged into `main`, and `flutter analyze` and
      `flutter test` pass on `main` (merge `ebfedd3`, 2026-09-16). Re-run
      both after any later change.
- [ ] Go through **Features to confirm before submitting** in `listing.md`.
      Everything listed there shipped; delete a description line only if
      its feature fails the device test below, then re-run the
      character-count script there.
- [ ] Test the **release build on a physical phone** (an emulator can
      exercise the UI, but not real centrals): pair with nRF Connect and a
      cycling app (for example Zwift), check power and cadence, run a test
      profile, and test Heart Rate, Speed & Cadence and screen-off
      broadcasting (turn the screen off for a few minutes mid-session and
      confirm the receiving app keeps getting data).

## 2. Developer account

- [ ] Create a Google Play Console developer account, pay the one-time
      registration fee, and complete identity verification.
- [ ] Note whether it is a **personal** or an **organization** account. It
      decides the testing requirement in step 10.

## 3. Upload key (once, and keep it safe)

The Gradle signing config is already wired in `android/app/build.gradle.kts`.
It signs release builds with `android/key.properties` when that file exists.
Without it, release builds fall back to the **debug** key, and Play rejects
those.

```bash
keytool -genkey -v -keystore ~/gotta-bike-ble-watts-upload.jks -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

On macOS, `/usr/bin/keytool` is only a stub: if it says "Unable to locate a
Java Runtime", use the `keytool` from the JDK that Flutter uses (`flutter
doctor -v` prints its path; on this machine it is
`/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/keytool`).
The same applies to the `keytool -printcert` check in step 5.

```bash
cp android/key.properties.example android/key.properties
```

- [ ] Fill in `storePassword`, `keyPassword`, `keyAlias` (`upload`) and the
      absolute `storeFile` path in `android/key.properties`.
- [ ] Keep the `.jks` file **outside the repo** and back it up (password
      manager or encrypted storage). `key.properties`, `*.jks` and
      `*.keystore` are git-ignored; never commit them.

## 4. Version

- [ ] Bump `version:` in `pubspec.yaml`. The part after `+` is the Android
      `versionCode` and must increase with **every** upload (for example
      `1.0.0+1` → `1.0.1+2`).

## 5. Build the App Bundle

Play requires an Android App Bundle (`.aab`) for new apps.

```bash
flutter build appbundle
```

The output is `build/app/outputs/bundle/release/app-release.aab`.

- [ ] Check that the bundle is signed with **your upload key, not the debug
      key**. The `Owner:` line must show your name, not `CN=Android Debug`:

```bash
keytool -printcert -jarfile build/app/outputs/bundle/release/app-release.aab
```

## 6. Create the app in Play Console

- [ ] **Create app**: name `GOTTA.BIKE: BLE Watts`, default language English
      (United States), **App**, **Free**, and accept the declarations.
- [ ] The package name comes from the first upload: `ble.make.bike.gotta`.
      It is **permanent**, so double-check it before uploading.

## 7. Play App Signing

- [ ] Keep the default, **Play App Signing**: Google holds the app signing
      key and you sign uploads with the upload key from step 3. If you ever
      lose the upload key, you can ask Google to reset it; the app signing
      key stays safe with Google.

## 8. Store listing (Grow users › Store presence › Main store listing)

- [ ] Paste the app name, short description and full description from
      `listing.md`.
- [ ] Upload `graphics/icon-512.png` (512×512) and
      `graphics/feature-graphic-1024x500.png` (1024×500, no alpha).
      **Verify** the current asset specs on the Preview assets page.
- [ ] Add phone screenshots of the app itself (at least 2, up to 8 per
      device type). Show only this app's UI, with no third-party logos.
      Good shots: the main screen while broadcasting, Test-profile mode with
      the chart, the profile picker, and Settings.
- [ ] Category **Tools** (reasoning in `listing.md`), up to 5 tags, and
      contact email, website and privacy-policy URL.

## 9. App content (Monitor and improve › App content)

- [ ] **Privacy policy**: host `privacy-policy.html` at a public URL (for
      example GitHub Pages), fill in its effective date and contact
      placeholders first, then paste the URL.
- [ ] **Ads**: no ads.
- [ ] **App access**: all functionality is available without special access
      (no login).
- [ ] **Content rating**: answer the IARC questionnaire using
      `content-rating.md`.
- [ ] **Target audience**: adults. Don't select any age group under 13, so
      the app stays out of the Families program.
- [ ] **Data safety**: answer using `data-safety.md` (no data collected or
      shared).
- [ ] **Health apps**: "My app doesn't provide any health features" (see
      `listing.md`, Category).
- [ ] **Foreground service permissions**. Required: screen-off broadcasting
      shipped. The app uses the `connectedDevice` type
      (`FOREGROUND_SERVICE_CONNECTED_DEVICE`, `BroadcastKeepAliveService`),
      so Play Console asks for each service type:
  - Use case: **Continuous Data Transfer to an External Device**.
  - Functionality description (ready to paste):

    ```text
    Optional "Keep broadcasting with screen off" setting. When the user turns it on and starts broadcasting, the app runs a connectedDevice foreground service with a persistent notification (with a Stop button). It keeps the Bluetooth LE advertising and the twice-per-second sensor notifications to the user's connected bike computer or cycling app running while the screen is off. It stops when the user stops broadcasting, taps Stop in the notification, or closes the app.
    ```

  - User impact if the task is deferred or interrupted (ready to paste):

    ```text
    The app stops sending sensor data, so the paired bike computer or cycling app loses the Bluetooth LE connection and stops receiving power and cadence, interrupting the user's test session. The user then has to reconnect the device and restart the session.
    ```

  - Video link: a short screen recording that turns the setting on in
    Settings, starts broadcasting, shows the notification, turns the screen
    off, and shows the receiving app still getting data. Upload it as an
    unlisted video and paste the link.

## 10. Testing tracks

- [ ] Upload the `.aab` to **Internal testing** first (quick to set up, up to
      100 testers). Install it through the opt-in link and run step 1's
      device tests on the Play-installed build.
- [ ] **Personal accounts created after November 13, 2023** must run a
      **closed test with at least 12 testers who stay opted in continuously
      for at least 14 days** before they can apply for production access. A
      tester who opts out and back in restarts their 14 days. **Verify**
      before planning, because Google has changed this rule before.
- [ ] Then apply for production access and answer the questions about your
      closed test.
- [ ] Organization accounts don't have this requirement, but a closed test
      is still worth running.

## 11. Target API level

- [ ] Since **August 31, 2026**, new apps and app updates must target
      **Android 16 (API level 36)** or higher (you can request an extension
      to November 1, 2026). This project targets API 36 through Flutter's
      default `targetSdkVersion`. After a Flutter upgrade, confirm it in the
      merged manifest under
      `build/app/intermediates/merged_manifest/release/`. **Verify** the rule
      again before each yearly deadline.

## 12. Release to production

- [ ] Create a production release with the same (or a newer) bundle, write
      release notes, and consider a **staged rollout**.
- [ ] Watch **Android vitals** and reviews for the first days.

## 13. Every update after that

- [ ] Bump the build number (step 4), build (step 5), and check the upload
      key signature again.
- [ ] Re-check the Data safety, content rating and foreground service
      answers whenever features or permissions change.

## Sources

- App testing requirements for new personal developer accounts (12 testers,
  14 days, closed testing):
  https://support.google.com/googleplay/android-developer/answer/14151465
- Target API level requirements (API 36 from August 31, 2026; extension to
  November 1, 2026):
  https://developer.android.com/google/play/requirements/target-sdk
- Foreground service declaration (App content; use cases; description, user
  impact and video per type):
  https://support.google.com/googleplay/android-developer/answer/13392821
- Create and set up your app:
  https://support.google.com/googleplay/android-developer/answer/9859152
- Preview assets (icon, feature graphic, screenshots):
  https://support.google.com/googleplay/android-developer/answer/9866151
- Sign your app (Flutter):
  https://docs.flutter.dev/deployment/android#sign-the-app
