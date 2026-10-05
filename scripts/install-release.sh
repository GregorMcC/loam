#!/bin/sh
# Install or update Loam from a GitHub release. It needs no Xcode and no Go.
#
#   curl -fsSL https://raw.githubusercontent.com/GregorMcC/loam/main/scripts/install-release.sh | sh
#   sh install-release.sh [--version TAG] [--prefix DIR] [--apps-dir DIR] [--force]
#
# It downloads Loam.zip from the latest release (or from TAG), checks its
# SHA-256 and its signature, and installs Loam.app in the apps folder (default
# /Applications). It links DIR/bin/loam (default DIR: $LOAM_PREFIX, else
# ~/.local) to the loam CLI inside Loam.app. When the installed Loam has the
# same version, it does nothing; --force installs anyway. When Loam runs, it
# quits Loam, installs, and opens Loam again. Run it again to update.
set -eu

releases="${LOAM_RELEASES_URL:-https://github.com/GregorMcC/loam/releases}"
# scripts/release.sh signs every release with the "Loam Local Signing"
# certificate. macOS keeps Loam's folder permissions only while it stays the same.
requirement="${LOAM_RELEASE_REQUIREMENT:-identifier \"dev.loam.Loam\" and certificate leaf = H\"72e22e0e1cdb829cff9a4de5e84804f49b5d6e18\"}"

usage() {
  echo "usage: install-release.sh [--version TAG] [--prefix DIR] [--apps-dir DIR] [--force]" >&2
}

prefix="${LOAM_PREFIX:-$HOME/.local}"
apps="${LOAM_APPS_DIR:-/Applications}"
version=""
force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || { usage; exit 2; }; version="$2"; shift 2 ;;
    --prefix) [ $# -ge 2 ] || { usage; exit 2; }; prefix="$2"; shift 2 ;;
    --apps-dir) [ $# -ge 2 ] || { usage; exit 2; }; apps="$2"; shift 2 ;;
    --force) force=1; shift ;;
    *) usage; exit 2 ;;
  esac
done

fail() {
  # fail MESSAGE [FIX]: print both and stop.
  echo "$1" >&2
  [ -z "${2:-}" ] || echo "Fix: $2" >&2
  exit 1
}

[ "$(uname -s)" = Darwin ] || fail "Loam runs on macOS only."
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] ||
  fail "Loam releases run on Apple silicon only." "build Loam from source: https://github.com/GregorMcC/loam#build-from-source"
macos=$(sw_vers -productVersion)
[ "${macos%%.*}" -ge 26 ] 2>/dev/null || fail "macOS $macos is too old. Loam needs macOS 26 or later." "update macOS in System Settings > General > Software Update"

if [ -n "$version" ]; then
  url="$releases/download/$version"
else
  url="$releases/latest/download"
fi

work=$(mktemp -d)
stage=""
trap 'rm -rf "$work" ${stage:+"$stage"}' EXIT

echo "Downloading Loam ${version:-(latest)}."
curl -fsSL -o "$work/Loam.zip" "$url/Loam.zip" || fail "Could not download $url/Loam.zip." "check the version and your network, then run this script again"
curl -fsSL -o "$work/Loam.zip.sha256" "$url/Loam.zip.sha256" || fail "Could not download $url/Loam.zip.sha256."
want=$(awk '{print $1; exit}' "$work/Loam.zip.sha256")
got=$(shasum -a 256 "$work/Loam.zip" | awk '{print $1}')
[ -n "$want" ] && [ "$want" = "$got" ] || fail "The download does not match its checksum. Nothing is installed." "run this script again"

# Stage in the apps folder, so the install is a rename on the same volume.
mkdir -p "$apps"
stage=$(mktemp -d "$apps/.Loam.XXXXXX")
ditto -x -k "$work/Loam.zip" "$stage" || fail "Could not unzip Loam.zip. Nothing is installed."
[ -d "$stage/Loam.app" ] || fail "Loam.zip holds no Loam.app. Nothing is installed."
why=$(codesign --verify --deep --strict -R="$requirement" "$stage/Loam.app" 2>&1) ||
  fail "The signature of Loam.app is not the signature of Loam releases. Nothing is installed.
codesign: $why"

new=$(/usr/libexec/PlistBuddy -c "Print :LoamVersion" "$stage/Loam.app/Contents/Info.plist" 2>/dev/null || echo unknown)
# PlistBuddy prints to stdout when the file is missing, so check the file first.
old=""
[ ! -f "$apps/Loam.app/Contents/Info.plist" ] ||
  old=$(/usr/libexec/PlistBuddy -c "Print :LoamVersion" "$apps/Loam.app/Contents/Info.plist" 2>/dev/null || echo unknown)
link_cli() {
  # The link points into Loam.app, so it stays correct across updates.
  mkdir -p "$prefix/bin"
  ln -sfn "$apps/Loam.app/Contents/Helpers/loam" "$prefix/bin/loam"
}

if [ "$force" -eq 0 ] && [ "$new" = "$old" ] && [ "$new" != unknown ]; then
  link_cli
  echo "Loam $new is installed. Nothing to do. Use --force to install it again."
  exit 0
fi

# The swap runs as its own script: when Loam runs, it must outlive this
# terminal, because quitting Loam closes a Loam pane.
cat > "$stage/swap.sh" <<'EOF'
set -eu
apps=$1 stage=$2 new=$3
fail() {
  echo "$1" >&2
  [ -z "${2:-}" ] || echo "Fix: $2" >&2
  exit 1
}
loam_running() {
  # -a: from a Loam pane, Loam is an ancestor, and pgrep skips ancestors without it.
  pgrep -af "^$apps/Loam.app/Contents/MacOS/Loam" >/dev/null 2>&1
}
trap 'rm -rf "$stage"' EXIT
reopen=0
if loam_running; then
  # Loam asks first when a session is mid-turn, so wait up to 10 minutes.
  echo "Quitting Loam. If Loam asks, choose Quit."
  osascript -e 'tell application id "dev.loam.Loam" to quit' >/dev/null 2>&1 ||
    fail "Could not ask Loam to quit. Nothing is installed." "quit Loam, then run the install again"
  waited=0
  while loam_running; do
    [ "$waited" -lt 600 ] || fail "Loam did not quit in 10 minutes. Nothing is installed." "quit Loam, then run the install again"
    sleep 1
    waited=$((waited + 1))
  done
  reopen=1
  # From here, a failure must not leave Loam closed: open the app that is in place.
  trap 'rm -rf "$stage"; open "$apps/Loam.app" 2>/dev/null || true' EXIT
fi
[ ! -e "$apps/Loam.app" ] || mv "$apps/Loam.app" "$stage/old"
if ! mv "$stage/Loam.app" "$apps/Loam.app"; then
  [ ! -e "$stage/old" ] || mv "$stage/old" "$apps/Loam.app"
  fail "Could not install $apps/Loam.app. The old app is restored."
fi
rm -rf "$stage"
trap - EXIT
echo "Installed $apps/Loam.app ($new)"
# Register the new bundle, so Spotlight and "open -a Loam" find it at once.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ ! -x "$lsregister" ] || "$lsregister" -f "$apps/Loam.app" >/dev/null 2>&1 || true
if [ "$reopen" -eq 1 ]; then
  if open "$apps/Loam.app"; then
    echo "Reopened Loam."
  else
    echo "Could not open Loam. Open it by hand."
  fi
fi
EOF

# -a: from a Loam pane, Loam is an ancestor, and pgrep skips ancestors without it.
if ! pgrep -af "^$apps/Loam.app/Contents/MacOS/Loam" >/dev/null 2>&1; then
  sh "$stage/swap.sh" "$apps" "$stage" "$new"
  stage=""
else
  log="$HOME/Library/Logs/loam-update.log"
  mkdir -p "$(dirname "$log")"
  : > "$log"
  # perl ships with macOS. setsid puts the swap in its own session, with no
  # terminal, so it lives on when Loam closes this pane.
  perl -MPOSIX -e 'POSIX::setsid() >= 0 or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"' \
    /bin/sh "$stage/swap.sh" "$apps" "$stage" "$new" </dev/null >>"$log" 2>&1 &
  pid=$!
  stage="" # the swap owns the staging folder now
  echo "Loam quits now, then opens again with $new."
  [ -z "${LOAM_PANE_SOCKET:-}" ] || echo "This pane closes when Loam quits. The log is $log."
  tail -n +1 -f "$log" &
  tailpid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
  done
  sleep 1 # let tail print the last lines
  kill "$tailpid" 2>/dev/null || true
  wait "$tailpid" 2>/dev/null || true
  grep -q "^Installed $apps/Loam.app" "$log" || fail "The install failed. The log is $log."
fi

link_cli
echo "Linked $prefix/bin/loam to the loam CLI in Loam.app."
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "$prefix/bin is not on your PATH. Add it in ~/.zshrc: export PATH=\"$prefix/bin:\$PATH\"" ;;
esac
if [ -z "$old" ]; then
  echo "Next: run 'loam setup' once. It registers the Loam MCP server with Claude Code."
  echo "Then open Loam: open \"$apps/Loam.app\""
fi
