#!/usr/bin/env bash
# Build the macOS app for download from the website (outside the Mac App
# Store): signed with Developer ID, notarized by Apple, stapled, in a DMG.
#
#   tool/release_macos.sh 1.2.3             build, sign, notarize and staple
#                                           the app and the DMG, then attach
#                                           the DMG to GitHub Release v1.2.3
#   tool/release_macos.sh 1.2.3 --dry-run   the same, but nothing is uploaded,
#                                           and problems that would stop a
#                                           real release are warnings
#   tool/release_macos.sh 1.2.3 --no-notarize
#                                           with --dry-run only: sign but skip
#                                           Apple's notary service (quick
#                                           local check; Gatekeeper will
#                                           reject the result)
#
# Run it AFTER tool/release.sh 1.2.3: it builds the commit tagged v1.2.3
# (formatter, analyzer and tests already passed there) and adds
# gotta-bike-ble-watts-macos.dmg and SHA256SUMS-macos.txt to that release.
# The DMG name has no version on purpose, so the website can always link
#   https://github.com/vincentdavis/GOTTA.BIKE-BLE-Watts/releases/latest/download/gotta-bike-ble-watts-macos.dmg
#
# One-time setup (store/macos-direct-download.md): a "Developer ID
# Application" certificate in the login keychain, and notary credentials
# saved with `xcrun notarytool store-credentials gotta-bike-notary`. Both
# stay in this Mac's keychain; nothing secret goes to GitHub. Override with
#   MACOS_SIGN_IDENTITY   e.g. "Developer ID Application: Jane Doe (AB12CD34EF)"
#                         (default: the only Developer ID Application
#                         identity in the keychain)
#   MACOS_NOTARY_PROFILE  notarytool keychain profile (default
#                         gotta-bike-notary)
#
# Needs Xcode, Flutter and, for the upload, the GitHub CLI (`gh auth
# login`). Written for the bash 3.2 that ships with macOS.
set -euo pipefail

die() { echo "release_macos: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

version="" dry_run=false notarize=true
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    --no-notarize) notarize=false ;;
    -h | --help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *) [ -z "$version" ] || die "unexpected argument: $arg"; version="${arg#v}" ;;
  esac
done
[ -n "$version" ] || die "usage: tool/release_macos.sh X.Y.Z [--dry-run [--no-notarize]]"
$notarize || $dry_run || die "--no-notarize only works with --dry-run: a release must be notarized."

problem() {
  if $dry_run; then echo "warning: $*" >&2; else die "$*"; fi
}

version_re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ "$version" =~ $version_re ]] || die "the version must look like 1.2.3 (got '$version')."
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
(( minor < 1000 && patch < 1000 )) || die "minor and patch must be below 1000."
code=$(( major * 1000000 + minor * 1000 + patch ))
tag="v$version"
min_macos=27
notary_profile="${MACOS_NOTARY_PROFILE:-gotta-bike-notary}"
entitlements=macos/Runner/DeveloperID.entitlements
dmg_name=gotta-bike-ble-watts-macos.dmg
volume_name="GOTTA.BIKE BLE Watts $version"

[ "$(uname -s)" = Darwin ] || die "this builds the macOS app, so it has to run on a Mac."
cd "$(git rev-parse --show-toplevel)"

step "Checking $tag for macOS (build $code)"
[ -d macos/Runner.xcodeproj ] || die "there is no macOS target (macos/Runner.xcodeproj)."
[ -f "$entitlements" ] || die "$entitlements is missing."
plutil -lint -s "$entitlements" || die "$entitlements isn't a valid plist."
[ -z "$(git status --porcelain)" ] || problem "the working tree has uncommitted changes."
git fetch --quiet --tags origin || problem "couldn't fetch from origin."
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  [ "$(git rev-parse HEAD)" = "$(git rev-parse "$tag^{commit}")" ] ||
    problem "HEAD isn't $tag; check it out first (git checkout $tag) so the Mac build matches the Android release."
else
  problem "tag $tag doesn't exist; run tool/release.sh $version first."
fi
pubspec_version=$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | tr -d '[:space:]')
[ "$pubspec_version" = "$version+$code" ] ||
  problem "pubspec.yaml says version $pubspec_version, expected $version+$code."
if ! $dry_run; then
  gh auth status >/dev/null 2>&1 || die "the GitHub CLI isn't logged in (run gh auth login)."
  gh release view "$tag" >/dev/null 2>&1 || die "GitHub Release $tag doesn't exist; run tool/release.sh $version first."
fi

# Find the signing identity: the one named, else the only Developer ID
# Application certificate in the keychain.
identities=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | sort -u)
if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
  identity="$MACOS_SIGN_IDENTITY"
  echo "$identities" | grep -qxF "$identity" ||
    die "no valid \"$identity\" signing identity in the keychain. Found:
${identities:-  (none)}"
else
  count=$(printf '%s' "$identities" | grep -c . || true)
  [ "$count" -ge 1 ] || die "no \"Developer ID Application\" certificate in the keychain (store/macos-direct-download.md, step 2)."
  [ "$count" -eq 1 ] || die "several Developer ID Application identities; pick one with MACOS_SIGN_IDENTITY:
$identities"
  identity="$identities"
fi
echo "Signing as: $identity"
if $notarize; then
  xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 ||
    die "notarytool can't use the keychain profile '$notary_profile' (store/macos-direct-download.md, step 3)."
fi

step "Building $version"
flutter pub get >/dev/null
flutter build macos --release --build-name="$version" --build-number="$code"
products=build/macos/Build/Products/Release
app=$(find "$products" -maxdepth 1 -name '*.app' -type d | head -n 1)
[ -n "$app" ] || die "no .app in $products."
app_name=$(basename "$app")

step "Checking the build"
plist="$app/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }
built="$(pb CFBundleShortVersionString) ($(pb CFBundleVersion))"
[ "$built" = "$version ($code)" ] || die "the app is version $built, expected $version ($code)."
min=$(pb LSMinimumSystemVersion)
[ "${min%%.*}" = "$min_macos" ] || problem "the app's minimum macOS is '$min', expected $min_macos.0 (MACOSX_DEPLOYMENT_TARGET)."
[ -n "$(pb NSBluetoothAlwaysUsageDescription)" ] ||
  die "Info.plist has no NSBluetoothAlwaysUsageDescription; macOS would kill the app when it first uses Bluetooth."
exe="$app/Contents/MacOS/$(pb CFBundleExecutable)"
echo "Bundle id: $(pb CFBundleIdentifier), minimum macOS $min, architectures: $(lipo -archs "$exe")"

step "Signing with Developer ID (hardened runtime)"
# A Developer ID build must not carry an App Store / development profile.
rm -f "$app/Contents/embedded.provisionprofile"
sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }
# Inside out: nested code first (deepest paths first), then the app with
# the entitlements. Only the app itself gets entitlements.
find "$app/Contents" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' \
  -o -name '*.app' -o -name '*.appex' -o -name '*.bundle' \) -print0 |
  while IFS= read -r -d '' item; do
    # A resource-only .bundle has no code to sign.
    if [ "${item##*.}" = bundle ] && [ ! -d "$item/Contents/MacOS" ]; then continue; fi
    sign "$item"
  done
sign --entitlements "$entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - || true

# Submits a file to Apple's notary service and waits; prints the log when
# Apple rejects it.
notarize_file() {
  local file="$1" out id status
  echo "Submitting $(basename "$file") to Apple (usually a few minutes)..."
  out=$(xcrun notarytool submit "$file" --keychain-profile "$notary_profile" --wait --output-format plist)
  id=$(echo "$out" | plutil -extract id raw - 2>/dev/null || true)
  status=$(echo "$out" | plutil -extract status raw - 2>/dev/null || true)
  if [ "$status" != Accepted ]; then
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$notary_profile" >&2 || true
    die "notarization of $(basename "$file") finished with status '${status:-unknown}' (submission ${id:-?})."
  fi
  echo "Accepted (submission $id)."
}

dist="build/release/$tag"
mkdir -p "$dist"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if $notarize; then
  step "Notarizing and stapling the app"
  # The app is stapled too, so it still opens offline after it's copied out
  # of the DMG.
  ditto -c -k --keepParent "$app" "$work/app.zip"
  notarize_file "$work/app.zip"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
fi

step "Building the DMG"
mkdir "$work/dmg"
ditto "$app" "$work/dmg/$app_name"
ln -s /Applications "$work/dmg/Applications"
dmg="$dist/$dmg_name"
rm -f "$dmg"
hdiutil create -volname "$volume_name" -srcfolder "$work/dmg" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
codesign --force --timestamp --sign "$identity" "$dmg"

if $notarize; then
  step "Notarizing and stapling the DMG"
  notarize_file "$dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

(cd "$dist" && shasum -a 256 -- "$dmg_name" > SHA256SUMS-macos.txt)
cat "$dist/SHA256SUMS-macos.txt"

if $dry_run; then
  step "Dry run finished: nothing was uploaded"
  $notarize || echo "Not notarized (--no-notarize): Gatekeeper will refuse this DMG on other Macs."
  ls -l "$dist"
  exit 0
fi

step "Attaching the DMG to GitHub Release $tag"
gh release upload "$tag" "$dmg" "$dist/SHA256SUMS-macos.txt" ||
  die "the upload failed. Retry with (add --clobber to replace existing files):
  gh release upload $tag $dmg $dist/SHA256SUMS-macos.txt"
gh release view "$tag" --json url --jq .url
