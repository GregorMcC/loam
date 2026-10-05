#!/bin/sh
# Build and install Loam from this repo.
#
#   scripts/install.sh core [--prefix DIR]
#   scripts/install.sh app [--prefix DIR] [--adhoc] [--apps-dir DIR] [--replace-running]
#
# The core binary goes to DIR/bin/loam (default DIR: $LOAM_PREFIX, else ~/.local).
# The app target installs the core first, then Loam.app into the apps folder
# (default /Applications). It signs with your Apple Development certificate, or
# else with the self-signed "Loam Local Signing" certificate that
# scripts/make-signing-cert.sh makes. --adhoc signs ad hoc instead.
# --replace-running builds while Loam runs, then quits Loam, installs, and
# opens the new Loam. scripts/update.sh uses it.
set -eu

usage() {
  echo "usage: scripts/install.sh core [--prefix DIR]" >&2
  echo "       scripts/install.sh app [--prefix DIR] [--adhoc] [--apps-dir DIR] [--replace-running]" >&2
}

target="${1:-}"
[ $# -gt 0 ] && shift
prefix="${LOAM_PREFIX:-$HOME/.local}"
apps="${LOAM_APPS_DIR:-/Applications}"
adhoc=0
replace=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || { usage; exit 2; }; prefix="$2"; shift 2 ;;
    --apps-dir) [ $# -ge 2 ] || { usage; exit 2; }; apps="$2"; shift 2 ;;
    --adhoc) adhoc=1; shift ;;
    --replace-running) replace=1; shift ;;
    *) usage; exit 2 ;;
  esac
done

case "$target" in
  core|app) ;;
  *) usage; exit 2 ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)

fail() {
  # fail MESSAGE [FIX]: print both and stop.
  echo "$1" >&2
  [ -z "${2:-}" ] || echo "Fix: $2" >&2
  exit 1
}

install_core() {
  if ! command -v go >/dev/null 2>&1; then
    fail "Go is not installed. Loam needs Go 1.26 or later." "brew install go"
  fi
  gover=$(go env GOVERSION | sed 's/^go//')
  major=${gover%%.*}
  rest=${gover#*.}
  minor=${rest%%.*}
  minor=${minor%%[!0-9]*}
  if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "${minor:-0}" -lt 26 ]; }; then
    fail "Go $gover is too old. Loam needs Go 1.26 or later." "brew upgrade go"
  fi

  version=$(git -C "$root" describe --tags --always --dirty 2>/dev/null || echo dev)
  bindir="$prefix/bin"
  mkdir -p "$bindir"
  tmp=$(mktemp "$bindir/.loam.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  (cd "$root/core" && go build -ldflags "-X github.com/GregorMcC/loam/core/internal/cli.Version=$version" -o "$tmp" ./cmd/loam)
  chmod 755 "$tmp"
  mv -f "$tmp" "$bindir/loam"
  trap - EXIT
  echo "Installed $bindir/loam ($version)"
}

loam_running() {
  # Only the installed bundle counts. A dev build or a test driver named Loam does not.
  # -a: from a Loam pane, Loam is an ancestor, and pgrep skips ancestors without it.
  pgrep -af "^$apps/Loam.app/Contents/MacOS/Loam" >/dev/null 2>&1
}

quit_loam() {
  # Ask Loam to quit, as Cmd-Q does. Loam asks first when a session is mid-turn,
  # so wait up to 10 minutes for an answer.
  echo "Quitting Loam. If Loam asks, choose Quit."
  osascript -e 'tell application id "dev.loam.Loam" to quit' >/dev/null 2>&1 ||
    fail "Could not ask Loam to quit. Nothing is installed." "quit Loam, then run scripts/update.sh again"
  waited=0
  while loam_running; do
    [ "$waited" -lt 600 ] || fail "Loam did not quit in 10 minutes. Nothing is installed." "quit Loam, then run scripts/update.sh again"
    sleep 1
    waited=$((waited + 1))
  done
}

find_identity() {
  ids=$(security find-identity -v -p codesigning 2>/dev/null)
  id=$(printf '%s\n' "$ids" | sed -n 's/.*\([0-9A-F]\{40\}\) "Apple Development.*/\1/p' | head -1)
  [ -n "$id" ] || id=$(printf '%s\n' "$ids" | sed -n 's/.*\([0-9A-F]\{40\}\) "Loam Local Signing".*/\1/p' | head -1)
  printf '%s' "$id"
}

no_certificate() {
  echo "No signing certificate found." >&2
  echo "Loam needs one so macOS keeps its folder permissions across updates." >&2
  echo "With no Apple developer team, make a local one: scripts/make-signing-cert.sh" >&2
  echo "Or create an Apple Development certificate in Xcode:" >&2
  echo "  1. Open Xcode, then Settings > Accounts." >&2
  echo "  2. Click +, choose Apple ID, and sign in." >&2
  echo "  3. Select the account and click Manage Certificates." >&2
  echo "  4. Click +, and choose Apple Development." >&2
  echo "  5. Check the result: security find-identity -v -p codesigning" >&2
  echo "To install now without the certificate, run: scripts/install.sh app --adhoc" >&2
  exit 1
}

install_app() {
  identity=-
  if [ "$adhoc" -eq 0 ]; then
    identity=$(find_identity)
    [ -n "$identity" ] || no_certificate
  fi
  [ "$replace" -eq 1 ] || ! loam_running || fail "Loam is running. Quit Loam, then run this script again."

  mkdir -p "$apps"
  stage=$(mktemp -d "$apps/.Loam.XXXXXX")
  trap 'rm -rf "$stage"' EXIT
  "$root/scripts/build-app.sh" "$stage" --identity "$identity"
  build=$(/usr/libexec/PlistBuddy -c "Print :LoamVersion" "$stage/Loam.app/Contents/Info.plist")

  # Check again: the build takes time, and Loam may have started since.
  reopen=0
  if loam_running; then
    [ "$replace" -eq 1 ] || fail "Loam is running. Quit Loam, then run this script again."
    quit_loam
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
  if [ "$adhoc" -eq 1 ]; then
    echo "Installed $apps/Loam.app ($build), signed ad hoc."
    echo "macOS may ask again for folder access after each update."
  else
    echo "Installed $apps/Loam.app ($build)"
  fi
  # Register the new bundle, so Spotlight and "open -a Loam" find it at once.
  lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  [ ! -x "$lsregister" ] || "$lsregister" -f "$apps/Loam.app" >/dev/null 2>&1 || true
  if [ "$reopen" -eq 1 ]; then
    if open "$apps/Loam.app"; then
      echo "Reopened Loam."
    else
      echo "Could not open Loam. Open it by hand."
    fi
  else
    echo "Open it with: open \"$apps/Loam.app\""
  fi
}

install_core
[ "$target" = app ] && install_app
[ "$replace" -eq 1 ] || echo "Next: run 'loam setup' once."
