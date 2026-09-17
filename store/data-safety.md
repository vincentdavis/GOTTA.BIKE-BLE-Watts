# Play Console Data safety form: GOTTA.BIKE: BLE Watts

Answers for **Play Console > Policy > App content > Data safety**. They are
based on the code on `main` at merge commit `ebfedd3` (which includes Heart
Rate and Speed & Cadence emulation, the profile editor and the optional
screen-off foreground service), its merged **release** manifest and
`pubspec.lock`. Re-check them against the final build before you submit
([when to revisit](#when-to-revisit-these-answers)).

## Answers at a glance

| Form step | Question | Answer |
|---|---|---|
| Data collection and security | Does your app collect or share any of the required user data types? | **No** |
| Data collection and security | Encryption in transit / data deletion questions | Not asked when the answer above is **No** (see note 2) |
| Data types | Which data types are collected or shared? | **None** (nothing to select) |
| Data usage and handling | Purposes, optional/required, ephemeral processing | **Not applicable** |
| Privacy policy (App content) | Privacy policy URL | `[PRIVACY POLICY URL]`, the hosted `store/privacy-policy.html` |
| Preview | Expected store label | "No data collected" and "No data shared with third parties" |

Google's help page says: "If your app collects or shares any of the required
user data types, select Yes. If not, select No." It also says: "Even
developers with apps that do not collect any user data must complete this
form and provide a link to their privacy policy." When no data is collected,
users see "No data collected" and "No data shared with third parties".
Source:
[Provide information for Google Play's Data safety section](https://support.google.com/googleplay/android-developer/answer/10787469).

## Why "No" is correct

Google defines the two terms like this (same source):

- **Collection**: "Transmitting data from your app off a user's device."
  "User data accessed by your app that is only processed locally on the
  user's device and not sent off device does not need to be disclosed."
- **Sharing**: "Transferring user data collected from your app to a third
  party". One exemption is a "user-initiated action ... where the user
  reasonably expects the data to be shared".

Here is what the app does, checked in the code:

1. **The app has no network access in release builds.** The merged release
   manifest has **no `android.permission.INTERNET`**. We checked
   `build/app/intermediates/packaged_manifests/release/processReleaseManifestForPackage/AndroidManifest.xml`,
   produced by a release build of merge commit `ebfedd3` (applicationId
   `ble.make.bike.gotta`, targetSdk 36, minSdk 24) on 2026-09-16. Its
   permissions are the Bluetooth ones, `FOREGROUND_SERVICE`,
   `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `WAKE_LOCK`, `POST_NOTIFICATIONS`
   (all for the optional screen-off mode, which runs no network code) and
   AndroidX's internal `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`. Only the debug and profile manifests
   (`android/app/src/debug/` and `android/app/src/profile/AndroidManifest.xml`)
   add `INTERNET`, which Flutter tooling needs for hot reload and debugging.
   The release app cannot open a network connection, so nothing can reach us
   or a third party.
2. **No SDK collects data.** The direct runtime dependencies are
   `universal_ble`, `wakelock_plus`, `shared_preferences` and
   `cupertino_icons` (`flutter_launcher_icons` is a dev-only build tool that
   is not part of the app). The screen-off foreground service is the app's
   own Kotlin code (`BroadcastKeepAliveService.kt`) with no third-party
   library.
   `pubspec.lock` has no analytics, advertising, crash-reporting or
   attribution SDK. It does contain `http`, but only as a transitive
   dependency of `package_info_plus`, which `wakelock_plus` uses on Linux.
   `http` is imported only in that package's web implementation, and the
   Android build has no `INTERNET` permission anyway. None of the Android
   plugin manifests (`universal_ble` 2.1.1, `wakelock_plus` 1.7.0,
   `shared_preferences_android` 2.4.27, `package_info_plus` 10.2.1) adds a
   network or advertising-ID permission, and the merged manifest has no
   `com.google.android.gms.permission.AD_ID`.
3. **Settings stay on the device.** Presets, BLE identity, profiles and
   sensor settings are written with `shared_preferences` to app-private
   storage (`lib/presets.dart`, `lib/device_identity.dart`,
   `lib/profile_store.dart`, `lib/sensor_config.dart`,
   `lib/screen_off_mode.dart`). That is on-device processing, not
   collection.
4. **The Bluetooth broadcast is neither collection nor sharing of user
   data.**
   - It happens only after the user taps **Start**
     (`_toggleAdvertising` in `lib/main.dart`). It goes to BLE apps and
     devices the user chooses to connect, and it is the app's whole purpose,
     so it is user-initiated and expected.
   - The values are **simulated**: numbers the user dials in or a scripted
     profile generates, not measurements of the user. So the emulated power
     and heart rate are not "Health info" or "Fitness info" about the user
     (Google: "Information about a user's fitness, such as exercise or other
     physical activity").
   - We (the developer) never receive any of it.
   - The advertised device name, manufacturer and model are labels for the
     emulated sensor. The privacy policy tells users not to put personal
     information in them.
5. **Location is never accessed.** `ACCESS_FINE_LOCATION` is declared with
   `android:maxSdkVersion="30"`. On Android 11 and lower it is required only
   for Bluetooth LE
   ([Bluetooth permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)).
   The app calls `UniversalBle.requestPermissions(withAndroidFineLocation:
   false)`, never reads location, and declares `BLUETOOTH_SCAN` with
   `usesPermissionFlags="neverForLocation"`.
6. **Connected-device identifiers are used only in memory.** The app calls
   `UniversalBlePeripheral.getSubscribedClients` only to display how many
   devices are subscribed. It never stores or transmits the IDs.
7. **Crash data.** The app has no crash or diagnostics SDK. The crash and
   ANR statistics in Play Console's Android vitals are collected by Google
   Play "from users who have opted in to automatically share usage and
   diagnostics data", not by the app
   ([Android vitals](https://support.google.com/googleplay/android-developer/answer/9844486)).
8. **Android Auto Backup.** `android:allowBackup` is not set, and it
   defaults to `true`, so Android's backup service may copy the app's shared
   preferences to the user's Google Drive. That backup is an OS and Google
   account feature the user controls. It is stored in a private folder we
   cannot read, and it is "end-to-end encrypted on devices running Android 9
   or higher"
   ([Auto Backup](https://developer.android.com/identity/data/autobackup)).
   The app itself transmits nothing. If you want settings never to leave the
   device, set `android:allowBackup="false"` in the manifest (outside this
   track's scope), then update the privacy policy's backup paragraph.

## Data types, one by one

Every row is **not collected, not shared**.

| Category | Data types | Reason |
|---|---|---|
| Location | Approximate, Precise | Never read. `ACCESS_FINE_LOCATION` exists only for BLE on Android 11 and lower (point 5). |
| Personal info | Name, Email, User IDs, Address, Phone, Race and ethnicity, Political or religious beliefs, Sexual orientation, Other | No accounts or forms. The BLE device name is an emulator label that stays on the device except in the user-initiated broadcast (point 4). |
| Financial info | Payment info, Purchase history, Credit score, Other | No purchases or payments. |
| Health and fitness | Health info, Fitness info | All emulated values are simulated and never sent to us (point 4). |
| Messages | Emails, SMS or MMS, In-app messages | None. |
| Photos and videos | Photos, Videos | None. |
| Audio files | Voice or sound recordings, Music files, Other | None. |
| Files and docs | Files and docs | None. The profile editor saves profiles in app-private preferences and has no file import or export. Re-check if import/export is added. |
| Calendar | Calendar events | None. |
| Contacts | Contacts | None. |
| App activity | App interactions, In-app search history, Installed apps, Other user-generated content, Other actions | No analytics. Presets and profiles stay on the device. |
| Web browsing | Web browsing history | No web view or browser. |
| App info and performance | Crash logs, Diagnostics, Other app performance data | No crash or diagnostics SDK (point 7). |
| Device or other IDs | Device or other IDs | None read or sent. Connected-central IDs are used only in memory (point 6). |

The categories come from the same Google help page. The data type names are
shortened here and may be worded slightly differently in Play Console.

## Notes for filling in the form

1. **Accounts.** The app has no sign-in and no accounts. Google's account
   deletion requirement applies "If your app enables account creation"
   ([account deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111)),
   so no deletion URL is needed. If the form asks about account creation,
   pick the option that says the app doesn't let users create an account.
   The exact wording can vary, so we have not quoted it.
2. **"Data is encrypted in transit" and "users can request deletion".**
   These follow a "Yes" answer to the collection question. With "No" they
   don't apply. If Play Console still shows them, answer truthfully: no data
   is transmitted to us, and users delete local data by clearing the app's
   storage or uninstalling.
3. **Keep the privacy policy consistent.** The Data safety answers,
   `store/privacy-policy.html` and the in-app privacy-policy link have to
   agree. Google's User Data policy requires "a privacy policy link or text
   within the app itself", in addition to the Play Console field
   ([User Data policy](https://support.google.com/googleplay/android-developer/answer/10144311)).
4. **Related App content declarations** (answers in
   `store/release-checklist.md`): Ads = No, Advertising ID = not used,
   Health apps = "My app doesn't provide any health features", Financial
   features = "My app doesn't provide any financial features", Government
   apps = No.

## When to revisit these answers

Update this form and the privacy policy **before** releasing any version
that:

- adds `android.permission.INTERNET` (check the merged release manifest
  after every dependency change), or any server, cloud sync, backup
  endpoint or web view;
- adds analytics, crash reporting (for example Firebase Crashlytics), ads,
  attribution or any SDK that sends data off the device;
- adds accounts or sign-in;
- reads **real** sensor data (a real heart-rate strap, power meter, GPS) or
  uploads ride files;
- adds sharing or export that sends data to a third party without a
  user-initiated action.

## Sources

- Data safety section: https://support.google.com/googleplay/android-developer/answer/10787469
- User Data policy (privacy policy requirement): https://support.google.com/googleplay/android-developer/answer/10144311
- Account deletion requirements: https://support.google.com/googleplay/android-developer/answer/13327111
- Android vitals: https://support.google.com/googleplay/android-developer/answer/9844486
- Bluetooth permissions: https://developer.android.com/develop/connectivity/bluetooth/bt-permissions
- Auto Backup: https://developer.android.com/identity/data/autobackup
