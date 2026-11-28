# macOS download from the website (outside the Mac App Store)

The Mac App Store build and this download are the same app, built from the
same `macos/` target with the same bundle id. What differs is how it is
signed:

| | Mac App Store | Website download |
|---|---|---|
| Certificate | Apple Distribution (Xcode) | **Developer ID Application** |
| Entitlements | `macos/Runner/Release.entitlements` | `macos/Runner/DeveloperID.entitlements` |
| Checked by | App Review | Apple's **notary service** (automated, minutes) |
| Built by | Xcode archive / upload | `tool/release_macos.sh` on this Mac |
| Delivered as | App Store | `gotta-bike-ble-watts-macos.dmg` on the GitHub Release |

Both use the App Sandbox with Bluetooth and user-selected files, so they
keep settings in the same container and a user can move between them.
Minimum macOS is 27 (`MACOSX_DEPLOYMENT_TARGET`), which runs only on Apple
silicon Macs.

Like Android releases, the build is signed and notarized **locally**: the
certificate and the notary credentials stay in this Mac's keychain and are
never stored on GitHub (see CLAUDE.md, Commands).

## One-time setup

### 1. Apple Developer Program

- [ ] The same paid membership as the iPhone/iPad and Mac App Store builds
      (USD 99 a year). Note the **Team ID** (10 characters, Membership
      details on developer.apple.com/account).

### 2. Developer ID Application certificate

Only the team's **Account Holder** can create Developer ID certificates.

- [ ] Xcode › Settings › Accounts › select the team › **Manage
      Certificates…** › **+** › **Developer ID Application**. Xcode creates
      the key in your login keychain and the certificate on Apple's side.
      (Alternatively: developer.apple.com › Certificates › **+** ›
      Developer ID Application, with a CSR from Keychain Access.)
- [ ] Check it is there:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

- [ ] **Back it up**: Keychain Access › My Certificates › right-click the
      "Developer ID Application: …" entry (with its private key) › Export
      as `.p12` with a strong password, into your password manager. Apple
      allows only a few Developer ID certificates per team, and it signs
      every downloaded build.

### 3. Notary credentials

- [ ] Create an **app-specific password** for your Apple Account at
      account.apple.com › Sign-In and Security › App-Specific Passwords
      (name it "notarytool").
- [ ] Save it in the keychain under the profile name the script uses:

```bash
xcrun notarytool store-credentials gotta-bike-notary --apple-id YOUR_APPLE_ID_EMAIL --team-id YOUR_TEAM_ID
```

It prompts for the app-specific password. (An App Store Connect API key
works too: `--key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>`.)
Check it with `xcrun notarytool history --keychain-profile gotta-bike-notary`.

### 4. Tools

- [ ] Xcode (with its command line tools), Flutter, and the GitHub CLI
      logged in (`gh auth login`), the same as for `tool/release.sh`.

## Every release

Cut the Android release first; it tags the version and creates the GitHub
Release. Then build the Mac download from the same tag:

```bash
tool/release.sh 1.3.0
git checkout v1.3.0
tool/release_macos.sh 1.3.0 --dry-run
tool/release_macos.sh 1.3.0
git checkout main
```

The script refuses to continue if HEAD isn't the tag, `pubspec.yaml`
disagrees, the tree is dirty, the GitHub Release is missing, or the
certificate or notary profile can't be found. It then:

1. Builds `flutter build macos --release` as `1.3.0 (1003000)` and checks
   the version, the minimum macOS (27) and the Bluetooth usage text.
2. Re-signs every framework and the app with the Developer ID certificate,
   the **hardened runtime** and a secure timestamp, using
   `DeveloperID.entitlements`, and removes any embedded provisioning
   profile.
3. Notarizes the app, staples the ticket to it, and checks it with
   Gatekeeper (`spctl`), so the app opens even offline after it's copied
   out of the DMG.
4. Builds a compressed DMG (the app plus an Applications shortcut, volume
   "GOTTA.BIKE BLE Watts 1.3.0"), signs, notarizes and staples it.
5. Uploads `gotta-bike-ble-watts-macos.dmg` and `SHA256SUMS-macos.txt` to
   GitHub Release `v1.3.0`. The files also stay in `build/release/v1.3.0/`.

A dry run does everything except the upload (it still notarizes, which
checks your credentials). `--dry-run --no-notarize` only signs, for a quick
local check; Gatekeeper rejects that DMG on other Macs.

If notarization fails, the script prints Apple's log, which names each
file that was rejected and why (usually an unsigned nested binary or a
missing timestamp).

## Website link

The DMG's file name has no version, so this link always gets the newest
release:

```text
https://github.com/vincentdavis/GOTTA.BIKE-BLE-Watts/releases/latest/download/gotta-bike-ble-watts-macos.dmg
```

"Latest" is the newest non-prerelease release, so upload the DMG to every
release (or the link breaks until you do).

## Test before you publish the link

- [ ] On a **different** Mac (or a new user account) that never built the
      app: download the DMG with a browser (so it gets the quarantine flag),
      open it, drag the app to Applications, and open it. It must open
      without "can't be checked for malicious software" or "damaged"
      warnings, and ask for Bluetooth permission on first use.
- [ ] Broadcast to nRF Connect or Zwift on another device, and run Dual
      record against a real sensor.
- [ ] Settings › Privacy & Security › Bluetooth lists the app after the
      first prompt.

## Things to know

- **The Mac can't keep broadcasting asleep.** Like iOS, there is no
  screen-off mode; the app keeps the display awake while it advertises
  (`wakelock_plus`). Closing the lid sleeps the Mac and drops the link.
- **Certificate expiry.** A Developer ID certificate lasts 5 years. Builds
  signed before it expires keep opening (thanks to the timestamp); new
  builds need a new certificate.
- **Revocation.** If the private key leaks, revoke the certificate on
  developer.apple.com: every app signed with it stops opening, so keep the
  `.p12` backup private.
- **Privacy.** The download collects nothing, same as the store builds, so
  `privacy-policy.md` / `.html` need no change for it.

## Sources

- Notarizing macOS software before distribution:
  https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Customizing the notarization workflow (`notarytool`, `stapler`):
  https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
- Developer ID: https://developer.apple.com/developer-id/
- Hardened Runtime:
  https://developer.apple.com/documentation/security/hardened-runtime
