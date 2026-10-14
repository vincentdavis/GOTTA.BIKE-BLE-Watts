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
- [ ] `tool/release.sh` signs GitHub releases with this key on this Mac
      (see [Releases on GitHub](#releases-on-github)); the key never goes to
      GitHub.

## 4. Version

- [ ] **Releases made with `tool/release.sh`** take their version from the
      command (`tool/release.sh 1.0.1` → versionName `1.0.1`, versionCode
      `1000001`), so there is nothing to bump: just use a higher version each
      time.
- [ ] **Local builds**: bump `version:` in `pubspec.yaml`. The part after `+`
      is the Android `versionCode` and must increase with **every** upload
      (for example `1.0.0+1` → `1.0.1+2`).

## 5. Build the App Bundle

Play requires an Android App Bundle (`.aab`) for new apps. `tool/release.sh`
already builds a signed `.aab` (and refuses a debug-signed one); it is
attached to the GitHub Release and kept in `build/release/vX.Y.Z/`, so you can
skip to step 6. To build one by hand instead:

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

## Releases on GitHub

Repo: https://github.com/vincentdavis/GOTTA.BIKE-BLE-Watts

Releases are built and signed **on this Mac** by `tool/release.sh`, then
uploaded to the repo's Releases page, so the upload key never leaves this
machine. GitHub only runs **CI** (`.github/workflows/ci.yml`) on every push
to `main` and every pull request: formatting, `flutter analyze`,
`flutter test`, an APK build and the analysis self-test. The CI APK (an
artifact kept 14 days) is signed with a throwaway debug key, so it's only for
quick tests and won't install over a release.

### Cutting a release

Needs `android/key.properties` (step 3), the GitHub CLI logged in
(`gh auth login`), and a clean `main` that is pushed to GitHub.

```bash
tool/release.sh 1.0.0 --dry-run
```

```bash
tool/release.sh 1.0.0
```

The dry run checks, tests and builds without tagging or uploading. The real
run then:

1. Refuses to continue if the tree is dirty, `main` isn't pushed, the version
   isn't higher than the last release, or the key file is missing.
2. Runs the formatter check, analyzer and tests.
3. Builds the APK and App Bundle as version `1.0.0` (versionCode `1000000`)
   and checks both are signed with the upload key, not the debug key.
4. Tags `v1.0.0`, pushes the tag, and creates the GitHub Release with the
   APK, the App Bundle and `SHA256SUMS.txt`. The release notes include the
   signing certificate's SHA-256 fingerprint.

The files also stay in `build/release/v1.0.0/`. If the upload fails after the
tag is pushed, the script prints the `gh release create` command to retry.

### Things to know

- [ ] **Signatures decide what installs over what.** Every release is signed
      with the upload key, so each one installs over the last. Builds signed
      with the debug key (`flutter run`, local builds without
      `key.properties`, CI artifacts) won't: uninstall the app once before
      switching. The same goes for Play: with Play App Signing, Google
      re-signs the app, so a phone can't move between the GitHub APK and the
      Play version without uninstalling.
- [ ] **Version codes only go up.** Android refuses to install a lower
      versionCode over a higher one, so the script won't release a version
      lower than the last one.
- [ ] **Back up the upload key.** Releases can only come from a machine that
      has it. Lose it and every user has to uninstall to move to a new key.
- [ ] **Keep CI's `FLUTTER_VERSION` current** in `.github/workflows/ci.yml`
      when you upgrade Flutter locally.

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
