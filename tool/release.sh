#!/usr/bin/env bash
# Build a signed Android release on this machine and publish it on GitHub.
#
#   tool/release.sh 1.2.3             check, test, build, tag v1.2.3, push the
#                                     tag and create the GitHub Release
#   tool/release.sh 1.2.3 --dry-run   check, test and build only: nothing is
#                                     tagged or uploaded, and problems that
#                                     would stop a real release are warnings
#
# The APK and App Bundle are signed with the upload key named in
# android/key.properties (store/release-checklist.md, step 3), so the key
# never leaves this machine. The version comes from the argument: 1.2.3
# builds versionName 1.2.3 and versionCode 1002003 (major * 1,000,000 +
# minor * 1,000 + patch), and it must be higher than every earlier release.
#
# Needs Flutter, the GitHub CLI (`gh auth login`), and a clean `main` that
# matches origin/main. Written for the bash 3.2 that ships with macOS.
set -euo pipefail

die() { echo "release: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

version="" dry_run=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    -h | --help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *) [ -z "$version" ] || die "unexpected argument: $arg"; version="${arg#v}" ;;
  esac
done
[ -n "$version" ] || die "usage: tool/release.sh X.Y.Z [--dry-run]"

# A problem that stops a real release; only a warning in a dry run.
problem() {
  if $dry_run; then echo "warning: $*" >&2; else die "$*"; fi
}

version_re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ "$version" =~ $version_re ]] || die "the version must look like 1.2.3 (got '$version')."
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
(( minor < 1000 && patch < 1000 )) || die "minor and patch must be below 1000."
code=$(( major * 1000000 + minor * 1000 + patch ))
tag="v$version"

cd "$(git rev-parse --show-toplevel)"

step "Checking $tag (versionCode $code)"
[ ! -e .github/workflows/release.yml ] ||
  die ".github/workflows/release.yml would build a second release from the tag; remove it."
[ -f android/key.properties ] ||
  problem "android/key.properties is missing, so the build would be signed with the debug key (see store/release-checklist.md, step 3)."
[ -z "$(git status --porcelain)" ] || problem "the working tree has uncommitted changes."
[ "$(git branch --show-current)" = main ] || problem "not on main."
git fetch --quiet --tags origin || problem "couldn't fetch from origin."
[ "$(git rev-parse HEAD)" = "$(git rev-parse -q --verify origin/main || true)" ] ||
  problem "main doesn't match origin/main; push or pull first."
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  problem "tag $tag already exists."
fi
highest=0 highest_tag=""
while read -r t; do
  [[ "${t#v}" =~ $version_re ]] || continue
  c=$(( BASH_REMATCH[1] * 1000000 + BASH_REMATCH[2] * 1000 + BASH_REMATCH[3] ))
  if (( c > highest )); then highest=$c highest_tag=$t; fi
done < <(git tag --list 'v*')
(( code > highest )) ||
  problem "$tag isn't higher than the latest release $highest_tag; Android won't install a lower version over a higher one."
$dry_run || gh auth status >/dev/null 2>&1 || die "the GitHub CLI isn't logged in (run gh auth login)."

# The JDK Flutter builds with (JAVA_HOME, else `flutter config --jdk-dir`)
# runs keytool and apksigner; on macOS /usr/bin/java is often just a stub.
jdk="${JAVA_HOME:-$(flutter config --list 2>/dev/null | awk '/jdk-dir:/ {print $2}')}"
[ -x "$jdk/bin/keytool" ] || die "can't find a JDK; set JAVA_HOME or run flutter config --jdk-dir."
export PATH="$jdk/bin:$PATH"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
build_tools="$(ls -d "$sdk"/build-tools/*/ 2>/dev/null | sort -V | tail -n 1)"
[ -x "${build_tools}apksigner" ] || die "can't find apksigner under $sdk/build-tools; set ANDROID_HOME."

step "Formatting, analyzer and tests"
flutter pub get >/dev/null
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test

step "Building $version"
flutter build apk --release --build-name="$version" --build-number="$code"
flutter build appbundle --release --build-name="$version" --build-number="$code"
apk=build/app/outputs/flutter-apk/app-release.apk
aab=build/app/outputs/bundle/release/app-release.aab

step "Checking the builds"
built=$("${build_tools}aapt2" dump badging "$apk" | sed -n "s/.*versionCode='\([0-9]*\)' versionName='\([^']*\)'.*/\2 (\1)/p")
[ "$built" = "$version ($code)" ] || die "the APK is version $built, expected $version ($code)."
apk_cert=$("${build_tools}apksigner" verify --print-certs "$apk")
aab_cert=$(keytool -printcert -jarfile "$aab")
echo "$apk_cert" | grep -E "certificate (DN|SHA-256)"
fingerprint=$(echo "$apk_cert" | sed -n 's/.*certificate SHA-256 digest: //p' | head -n 1)
if echo "$apk_cert $aab_cert" | grep -q "CN=Android Debug"; then
  problem "the builds are signed with the debug key, not your upload key."
fi

dist="build/release/$tag"
rm -rf "$dist"
mkdir -p "$dist"
cp "$apk" "$dist/gotta-bike-ble-watts-$version.apk"
cp "$aab" "$dist/gotta-bike-ble-watts-$version.aab"
(cd "$dist" && shasum -a 256 -- *.apk *.aab > SHA256SUMS.txt)
notes="build/release/$tag-notes.md"
cat > "$notes" <<EOF
**Install on an Android phone:** download \`gotta-bike-ble-watts-$version.apk\` and open it (allow installs from your browser or file manager when asked). It installs over earlier releases from this page.

\`.aab\` is the App Bundle for Google Play uploads. \`SHA256SUMS.txt\` has checksums for both files.

Signing certificate SHA-256: \`$fingerprint\`
EOF

if $dry_run; then
  step "Dry run finished: nothing was tagged or uploaded"
  ls -l "$dist"
  exit 0
fi

step "Tagging $tag and pushing the tag"
git tag -a "$tag" -m "GOTTA.BIKE BLE Watts $version"
git push origin "$tag"

step "Creating the GitHub Release"
title="GOTTA.BIKE BLE Watts $version"
if ! gh release create "$tag" "$dist"/* --verify-tag --title "$title" \
  --notes-file "$notes" --generate-notes; then
  die "$tag is pushed but the release wasn't created. Retry with:
  gh release create $tag $dist/* --verify-tag --title \"$title\" --notes-file $notes --generate-notes"
fi
gh release view "$tag" --json url --jq .url
