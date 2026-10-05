#!/bin/sh
# Build Loam.app into a folder.
#
#   scripts/build-app.sh OUT [--identity ID] [--cli PATH]
#
# It builds the app icon, GhosttyKit, and the Swift app, and assembles
# OUT/Loam.app. It signs with ID (a certificate name or SHA-1 hash), else ad
# hoc. --cli copies the loam binary at PATH into Contents/Helpers/loam and signs
# it too. scripts/install.sh and scripts/release.sh use this script.
set -eu

usage() {
  echo "usage: scripts/build-app.sh OUT [--identity ID] [--cli PATH]" >&2
}

[ $# -ge 1 ] || { usage; exit 2; }
out="$1"
shift
identity=-
cli=""
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) [ $# -ge 2 ] || { usage; exit 2; }; identity="$2"; shift 2 ;;
    --cli) [ $# -ge 2 ] || { usage; exit 2; }; cli="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

root=$(cd "$(dirname "$0")/.." && pwd)

fail() {
  # fail MESSAGE [FIX]: print both and stop.
  echo "$1" >&2
  [ -z "${2:-}" ] || echo "Fix: $2" >&2
  exit 1
}

check_xcode() {
  ver=$(xcodebuild -version 2>/dev/null | sed -n '1s/^Xcode //p')
  [ -n "$ver" ] || fail "Xcode is not installed." "install Xcode 26.5 or later, then run: sudo xcode-select -s /Applications/Xcode.app"
  major=${ver%%.*}
  rest=${ver#*.}
  minor=${rest%%.*}
  major=${major%%[!0-9]*}
  minor=${minor%%[!0-9]*}
  if [ "${major:-0}" -lt 26 ] || { [ "${major:-0}" -eq 26 ] && [ "${minor:-0}" -lt 5 ]; }; then
    fail "Xcode $ver is too old. Loam needs Xcode 26.5 or later." "install Xcode 26.5 or later, then run: sudo xcode-select -s /Applications/Xcode.app"
  fi
}

check_metal() {
  xcrun metal --version >/dev/null 2>&1 ||
    fail "The Metal Toolchain is not installed." "xcodebuild -downloadComponent MetalToolchain"
}

check_xcode
check_metal
[ -z "$cli" ] || [ -x "$cli" ] || fail "No loam binary at $cli."
[ ! -e "$out/Loam.app" ] || fail "$out/Loam.app already exists."

# The app icon first: it takes a second, and a failure here costs no build time.
icon=$(mktemp -d)
trap 'rm -rf "$icon"' EXIT
"$root/scripts/build-icon.sh" "$icon" || fail "Could not build the app icon."

"$root/scripts/build-ghosttykit.sh"

build=$(git -C "$root" describe --tags --always --dirty 2>/dev/null || echo dev)
# The short version is the last release tag without its v. Before the first tag it is 0.1.0.
short=$(git -C "$root" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)
(cd "$root/app" && swift build -c release --product Loam)
bin=$(cd "$root/app" && swift build -c release --show-bin-path)/Loam

app="$out/Loam.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Loam"
# The Ghostty resources: themes and shell integration in ghostty/, and terminfo beside it.
share="${LOAM_VENDOR:-$root/app/vendor}/ghostty-share"
[ -d "$share/ghostty" ] && [ -d "$share/terminfo" ] ||
  fail "No Ghostty resources in $share. Run scripts/build-ghosttykit.sh, then this script again."
cp -R "$share/ghostty" "$share/terminfo" "$app/Contents/Resources/"
# The Loam Night and Day terminal themes. The app writes a defaults file that points here.
[ -f "$root/app/Resources/ghostty-themes/loam-night" ] && [ -f "$root/app/Resources/ghostty-themes/loam-day" ] ||
  fail "The Loam themes are missing in app/Resources/ghostty-themes. Run scripts/gen-loam-theme.py."
cp -R "$root/app/Resources/ghostty-themes" "$app/Contents/Resources/"
# The app icon: Assets.car and AppIcon.icns, compiled from app/Resources/AppIcon.icon.
cp "$icon/Assets.car" "$icon/AppIcon.icns" "$app/Contents/Resources/"
count=$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)
sed -e "s/__BUILD__/$count/" -e "s/__VERSION__/$build/" -e "s/__SHORT_VERSION__/${short:-0.1.0}/" \
  "$root/scripts/Info.plist" > "$app/Contents/Info.plist"
if [ -n "$cli" ]; then
  # Helpers, not MacOS: on a volume that ignores case, MacOS/loam is MacOS/Loam.
  # Nested code is signed before the bundle that seals it.
  mkdir -p "$app/Contents/Helpers"
  cp "$cli" "$app/Contents/Helpers/loam"
  codesign --force --sign "$identity" "$app/Contents/Helpers/loam"
fi
codesign --force --sign "$identity" "$app"
