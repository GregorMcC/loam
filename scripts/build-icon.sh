#!/bin/sh
# Compile the Loam app icon into a folder.
#
#   scripts/build-icon.sh DIR
#
# The source is app/Resources/AppIcon.icon, a layered Icon Composer icon. actool writes
# Assets.car (the macOS 26 glass icon and its dark, tinted and clear variants) and
# AppIcon.icns (the flat fallback) into DIR. Info.plist names both as AppIcon.
set -eu

[ $# -eq 1 ] || { echo "usage: scripts/build-icon.sh DIR" >&2; exit 2; }
out="$1"
root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/app/Resources/AppIcon.icon"
[ -f "$src/icon.json" ] || { echo "The app icon source is missing: $src" >&2; exit 1; }
mkdir -p "$out"
log=$(mktemp)
trap 'rm -f "$log" "$log.plist"' EXIT
if ! xcrun actool "$src" \
  --compile "$out" \
  --platform macosx \
  --target-device mac \
  --minimum-deployment-target 26.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$log.plist" \
  --output-format human-readable-text >"$log" 2>&1; then
  cat "$log" >&2
  echo "actool could not compile $src" >&2
  exit 1
fi
if [ ! -s "$out/Assets.car" ] || [ ! -s "$out/AppIcon.icns" ]; then
  cat "$log" >&2
  echo "actool did not write Assets.car and AppIcon.icns into $out" >&2
  exit 1
fi
