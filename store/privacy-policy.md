# Privacy Policy: GOTTA.BIKE: BLE Watts

<!--
Owner notes (not part of the published policy):
- Fill in every [PLACEHOLDER] before you publish.
- Keep this file and store/privacy-policy.html in sync. The HTML is the
  version you host (for example on GitHub Pages) and link from Play Console
  and from inside the app.
- Heart Rate / Speed & Cadence emulation, the profile editor and screen-off
  broadcasting (foreground service + wake lock) all shipped (main,
  2026-09-16), so every passage below applies.
- Re-check the permission list against the merged release manifest before
  every release (see store/release-checklist.md).
-->

**Effective date:** [EFFECTIVE DATE]

This privacy policy describes how the Android app **GOTTA.BIKE: BLE Watts**
(package name `ble.make.bike.gotta`, "the app") handles information. The app
is published by [DEVELOPER LEGAL NAME] under the GOTTA.BIKE brand ("we",
"us").

## Summary

- The app has **no accounts, no ads, no analytics and no tracking**.
- **We do not collect, receive, sell or share any personal data.** The app
  has no servers, and the Android release build doesn't request Android's
  Internet permission.
- Your settings (presets, device identity, test profiles and sensor
  settings) are **stored only on your device**.
- When you tap **Start**, the app broadcasts **simulated** sensor data over
  Bluetooth Low Energy (BLE) to nearby devices. Anyone nearby can see that
  broadcast, so **keep personal information out of the device name**.

## What the app does

The app makes your phone act as a standard Bluetooth LE cycling sensor so you
can test cycling apps, bike computers and indoor-training setups. All values
it sends (power, cadence, heart rate, speed) are simulated: they are numbers
you choose or a scripted test profile produces. **The app does not measure
anything about you.**

## Information we collect

**None.** The app doesn't send any information to us or to any third party.
We have no user database, and the app contains no advertising, analytics or
crash-reporting software.

## Information stored on your device

The app saves the following settings in its private storage on your phone,
so they are still there the next time you open it:

- **Presets:** up to five named power and cadence levels.
- **Device identity:** the advertised Bluetooth device name and the
  manufacturer and model strings.
- **Test profiles:** custom power profiles you create in the profile editor,
  and which profile is selected.
- **Sensor and app settings:** settings for the emulated sensors, such as
  which sensors are on and their values, and app preferences such as the
  screen-off broadcasting option.

Other apps can't read this data (Android keeps each app's private storage
separate), and we never receive it. You can change or delete presets and
profiles in the app. To delete everything, use Android's **Clear storage**
option for the app, or uninstall it.

**Android backup.** If Android backup is turned on for your Google account,
Android may include these settings in your device backup so they can be
restored on a new phone. Google stores these backups in your Google account.
On Android 9 and newer they are end-to-end encrypted with your screen lock
PIN, pattern or password. We can't access them. You control backup in your
phone's settings.

## Bluetooth: what the app broadcasts

The app sends Bluetooth data only after you tap **Start**, and it stops when
you tap **Stop**. While it is broadcasting:

- It **advertises** the device name you chose (default "GOTTA.BIKE Watts")
  and the standard sensor services it offers. Any Bluetooth device in range
  can see the advertisement.
- To advertise that name, Android temporarily uses it as **your phone's
  Bluetooth name**. The app restores your original name when you tap Stop.
  If the app is closed unexpectedly while broadcasting, your phone may keep
  the emulator's name. You can change it back under Bluetooth settings in
  Android.
- Apps and devices that **connect** to it can read the manufacturer and model
  strings you set and receive the simulated sensor values. These are the
  standard Cycling Power data (power and crank revolution data, from which
  receivers calculate cadence) and, if you turn those sensors on in Settings,
  Heart Rate and Cycling Speed and Cadence data.
- The app's Bluetooth services don't require pairing, so the data isn't
  protected from other nearby devices. **Don't put personal information such
  as your full name in the device name.**
- The app shows how many devices are connected. It doesn't store or send the
  identifiers of those devices.
- Your phone's Bluetooth address is assigned by Android. The app can't read or
  change it.

What a connected app or device does with the values it receives is governed
by that app's or device's own privacy policy.

## Permissions the app uses

| Permission | Android versions | Why the app needs it |
|---|---|---|
| `BLUETOOTH_ADVERTISE` (Nearby devices) | 12 and newer | To advertise the emulated sensor so other devices can find it. Requested when you first tap Start. |
| `BLUETOOTH_CONNECT` (Nearby devices) | 12 and newer | To accept connections from apps and devices, send them sensor data, and apply the advertised device name. |
| `BLUETOOTH_SCAN` (Nearby devices) | 12 and newer | Required by the Bluetooth library the app uses. It is declared with the `neverForLocation` flag: the app never uses Bluetooth to work out your location, and it doesn't scan for or record nearby devices. |
| `BLUETOOTH`, `BLUETOOTH_ADMIN` | 11 and older only | The older Bluetooth permissions that Android 11 and older use for the same purpose. |
| `ACCESS_FINE_LOCATION` (Location) | 11 and older only | On Android 11 and older, Android ties Bluetooth LE to the location permission, and the Bluetooth library the app uses requires it on those versions. The app **never reads, stores or shares your location**. On Android 12 and newer the app doesn't request location at all. |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE` | 9 and newer; the second one on 14 and newer | Only for the optional screen-off broadcasting feature. It lets the app keep sending Bluetooth data to a connected device while the screen is off. |
| `WAKE_LOCK` | All | Only for the optional screen-off broadcasting feature. It keeps the phone's processor running while the screen is off, so the app can keep sending sensor data. It is released when broadcasting stops. |
| `POST_NOTIFICATIONS` (Notifications) | 13 and newer | Only for the optional screen-off broadcasting feature. It shows the notification that tells you the app is still broadcasting. Requested when you turn the option on. |

**Screen on.** While it is broadcasting, the app keeps your screen on as
long as the app is open, so Android doesn't pause it. This uses a standard
display setting and needs no permission. When you tap Stop, the screen goes
back to its normal timeout.

**Screen-off broadcasting (optional).** If you turn this option on in
Settings, the app also runs an Android foreground service and keeps the
processor awake while it broadcasts, so broadcasting keeps going if the
screen turns off or you switch apps. Android shows a notification with a
Stop button while it runs. The service stops when you stop broadcasting or
close the app. Enabling it doesn't make the app collect any data.

## Third parties

The app doesn't include any third-party advertising, analytics or tracking
SDKs, and it doesn't share data with anyone.

You download the app from Google Play, which is operated by Google under
Google's own privacy policy. Through Google Play Console, Google gives app
developers aggregated statistics (for example install counts). It also gives
technical reports such as crash reports from users who chose to share usage
and diagnostics data. Google collects that information, not the app.

## Children

The app is a testing tool and is not directed at children. We don't
knowingly collect personal information from anyone, including children.

## Security

Your settings stay in the app's private storage, which Android's app sandbox
protects. The app doesn't transmit your data over the internet. Bluetooth
broadcasts are unencrypted by design (see above), so don't put anything
sensitive into the fields that the app broadcasts.

## Data retention and deletion

We don't hold any of your data, so there is nothing for us to keep or delete.
Settings stored on your phone stay there until you change them, clear the
app's storage or uninstall the app.

## Your choices

- You can deny or revoke the Nearby devices, Location or Notifications
  permissions at any time in Android settings. Without them the app can't
  broadcast, or can't show its notification.
- You can stop broadcasting at any time with the Stop button.
- You can turn Android backup on or off in your phone's settings.

## Changes to this policy

If the app's data practices change, for example if a future version adds a
feature that needs to send data off your device, we will update this policy
and its effective date before that version is released. We will also update
the app's Google Play Data safety information.

## Contact

Questions about this policy or the app:

- Email: [CONTACT EMAIL]
- Website: [WEBSITE URL]
- Developer: [DEVELOPER LEGAL NAME], GOTTA.BIKE

*GOTTA.BIKE: BLE Watts is an independent app. It is not affiliated with or
endorsed by Zwift, Garmin, Wahoo or the Bluetooth SIG. The Bluetooth® word
mark and logos are registered trademarks owned by Bluetooth SIG, Inc.*
