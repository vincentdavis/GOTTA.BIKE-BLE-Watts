# Windows download: GOTTA.BIKE: BLE Watts

The Windows app is the same Flutter app, built for Windows 10/11 x64 and
offered as a download from the website (not the Microsoft Store, for now).
This page covers what works, how the files are built, and what code signing
it needs before a public release.

## Status

- **Builds:** `.github/workflows/windows.yml` builds it on every push to
  `main` and every pull request. Not yet tried on a real Windows PC with a
  real central (Zwift, a head unit, nRF Connect).
- **Signed:** no. See [Code signing](#code-signing) before linking it from
  the website.

## Does BLE work on Windows?

Yes, with limits. `universal_ble` (2.1.x) supports both roles on Windows:

| Feature | Windows | Notes |
| :-- | :-: | :-- |
| Emulate Cycling Power / Heart Rate / Speed & Cadence (peripheral) | yes | via WinRT `GattServiceProvider` |
| Custom advertised name ("GOTTA.BIKE Watts") | **no** | Windows can't put an app-chosen name in the advertisement. Apps list the PC by its own Bluetooth name (Settings › System › About › Rename this PC), or as an unnamed sensor. The Settings screen and status line say so on Windows. |
| Device Information (manufacturer / model) | yes | Windows only publishes services that are advertising, so on Windows `0x180A` is advertised too (there is no name competing for the 31 bytes). |
| Notify, connected-apps count | yes | |
| Dual record (central: scan, connect, subscribe) | yes | |
| Keep broadcasting with screen off | n/a | Android-only switch; on Windows the app keeps running in the background anyway, and the wakelock keeps the display on while broadcasting. |
| Import CSV ride, save/share Dual-record CSV | yes | CSVs go to `Documents\GOTTA.BIKE BLE Watts\recordings`. Sharing files needs Windows 10 1809+. |

What the PC needs:

- Windows 10 version 1809 (build 17763) or later, or Windows 11; x64 (ARM
  PCs run it under emulation). The installer refuses older Windows.
- Bluetooth LE with the **peripheral role** (WinRT
  `BluetoothAdapter.IsPeripheralRoleSupported`). Many built-in adapters
  have it; older USB dongles often don't, and Windows Settings doesn't show
  it. The quickest test is to press Start in the app: without the role,
  setup or Start fails with an error from Windows (the plugin only checks
  that a radio exists). Dual record still works.
- A PC running Zwift and this app at once **can't** pair Zwift with the
  app on the same PC: a Bluetooth adapter doesn't connect to itself. Run the
  centrals (Zwift, head unit) on another device, or use this app's Dual
  record against real sensors.

## Building

Flutter can't cross-compile Windows apps, so the Mac can't build them. Use
GitHub Actions (normal route) or a Windows PC.

**On GitHub:** every push to `main` and every PR uploads an artifact
`windows-unsigned-<version>-<sha>` (14 days) holding:

- `GOTTA.BIKE-BLE-Watts-<version>-windows-x64-setup.exe` (installer)
- `GOTTA.BIKE-BLE-Watts-<version>-windows-x64.zip` (portable: unzip, run
  `gotta_bike_ble_watts.exe`)
- `SHA256SUMS-windows.txt`

**Attaching to a release:** after `tool/release.sh X.Y.Z` has created
`vX.Y.Z`, run Actions › **Windows** › Run workflow with `release_tag` =
`vX.Y.Z`. It builds that tag and uploads the three files to the release.
The release's own `SHA256SUMS` only covers the Android files;
`SHA256SUMS-windows.txt` covers the Windows ones.

**On a Windows PC:** install Flutter (same version as `FLUTTER_VERSION` in
the workflows), Visual Studio 2022 or its Build Tools with "Desktop
development with C++", and Inno Setup 6, then:

```powershell
flutter pub get
pwsh tool/build_windows.ps1            # version from pubspec.yaml
pwsh tool/build_windows.ps1 -Version 1.2.0
```

The files land in `build\windows\dist\`. `flutter run -d windows` runs a
debug build.

Notes on the build:

- The installer (`windows/installer/setup.iss`, Inno Setup 6) installs per
  user by default (no admin prompt), adds a Start menu shortcut, an optional
  desktop shortcut, and an uninstaller. Its `AppId` GUID must never change,
  or upgrades install side by side.
- The Visual C++ runtime DLLs are copied next to the exe, so the app runs on
  PCs without the VC++ Redistributable.
- Windows versions are `X.Y.Z.0`: Windows version parts are 16-bit, so the
  Android versionCode (e.g. 1002000) can't be used as the build number.
- The icon is `windows/runner/resources/app_icon.ico`, generated from
  `assets/icon/icon.png` by `python3 assets/icon/generate_icon.py` (the
  `windows:` block in `flutter_launcher_icons.yaml`).

## Code signing

Unsigned downloads work, but Windows treats them as untrusted:

- **SmartScreen** shows "Windows protected your PC" on the installer; users
  must click *More info › Run anyway*. Many people stop there.
- Some antivirus products and company PCs block unsigned installers.
- Browsers (Edge, Chrome) may warn on the download itself.

To fix that, sign `gotta_bike_ble_watts.exe` (before packaging) and the
setup `.exe` (after) with an Authenticode certificate. Since June 2023 a
code-signing key must live in a hardware module or a cloud HSM, so a
`.pfx` file in a GitHub secret is no longer an option. The realistic
choices:

| Option | Cost (approx.) | SmartScreen | Fits CI? | Notes |
| :-- | :-- | :-- | :-- | :-- |
| **Azure Trusted Signing** (being renamed Artifact Signing) | ~US$10/month | Trusted from the first download | Yes: GitHub OIDC, Microsoft's signing action | Easiest. Identity validation for individuals or organisations; check current country/age-of-business requirements. Recommended. |
| OV certificate from a CA (cloud signing, e.g. SSL.com eSigner, DigiCert KeyLocker) | ~US$200–400/year + cloud-signing fees | Builds reputation over downloads | Yes, via the CA's CLI | Warnings fade as downloads accumulate. |
| EV certificate on a USB token | ~US$300–600/year | Since 2024 no longer bypasses SmartScreen reputation | No: needs the token plugged in | Only for local signing on a Windows PC. |
| Microsoft Store (MSIX) | US$0 for individuals | Store apps aren't flagged | Partly | Microsoft signs Store packages. Needs an MSIX build (the `msix` package) and Store review; a separate project. |

Once signing is chosen, add two steps to `tool/build_windows.ps1` (or the
workflow): sign the exe in `build\windows\x64\runner\Release` before the zip
and installer are made, and sign the setup `.exe` after. Use SHA-256 and a
timestamp server (`signtool sign /fd sha256 /tr <timestamp-url> /td sha256`)
so signatures stay valid after the certificate expires. Signing secrets go
in a GitHub environment that only the manual release run can use, never in
PR builds.

## Website download

- Link to the GitHub release asset
  (`https://github.com/vincentdavis/GOTTA.BIKE-BLE-Watts/releases/latest`)
  rather than hosting the files, so the site never serves stale builds.
- List the requirements above (Windows 10 1809+/11, BLE adapter with the
  peripheral role, run Zwift on another device) and the "no custom name"
  limit.
- Until the files are signed, explain the SmartScreen prompt and publish the
  SHA-256 sums.
- The privacy policy applies unchanged: the Windows app collects nothing
  either and only stores settings and recordings on the PC.

## Before the first public Windows release

1. Install the CI build on a real Windows 10 and 11 PC; check broadcast to
   nRF Connect / Zwift on a second device, Dual record, CSV import, saving
   and sharing a recording, uninstall, and an upgrade over an older version.
2. Decide the name problem is acceptable (it is a Windows limit) and write
   it on the website.
3. Set up code signing (above) and add the signing steps.
4. Add the Windows build to the website's download page.
