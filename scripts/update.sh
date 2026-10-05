#!/bin/sh
# Update Loam from origin.
#
#   scripts/update.sh [--force] [--adhoc]
#
# It fetches origin and fast-forwards main in this checkout. Then it builds
# and installs the core and the app, as scripts/install.sh app does. It stops
# when the checkout is not on main or has uncommitted changes.
#
# When the installed loam already has this commit, it does nothing. --force
# builds and installs anyway. --adhoc goes to install.sh.
#
# When Loam runs, the build runs in the background, so it outlives a Loam pane.
# It quits Loam when the build is done, installs, and opens the new Loam. Its
# log is ~/Library/Logs/loam-update.log.
set -eu

usage() {
  echo "usage: scripts/update.sh [--force] [--adhoc]" >&2
}

force=0
pass=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force=1; shift ;;
    --adhoc) pass="--adhoc"; shift ;;
    *) usage; exit 2 ;;
  esac
done

root=$(cd "$(dirname "$0")/.." && pwd)
apps="${LOAM_APPS_DIR:-/Applications}"
prefix="${LOAM_PREFIX:-$HOME/.local}"
log="$HOME/Library/Logs/loam-update.log"

fail() {
  # fail MESSAGE [FIX]: print both and stop.
  echo "$1" >&2
  [ -z "${2:-}" ] || echo "Fix: $2" >&2
  exit 1
}

branch=$(git -C "$root" branch --show-current)
[ "$branch" = main ] || fail "The Loam checkout $root is on ${branch:-a detached HEAD}, not main." "git -C \"$root\" switch main"
[ -z "$(git -C "$root" status --porcelain --untracked-files=no)" ] ||
  fail "The Loam checkout $root has uncommitted changes." "commit or stash them, then run this script again"

before=$(git -C "$root" rev-parse --short HEAD)
git -C "$root" fetch --quiet origin || fail "Could not fetch from origin."
[ "$(git -C "$root" rev-list --count origin/main..HEAD)" -eq 0 ] ||
  fail "main has commits that origin/main does not have." "push them, or reset main to origin/main, then run this script again"
git -C "$root" merge --ff-only --quiet origin/main || fail "Could not fast-forward main to origin/main."
after=$(git -C "$root" rev-parse --short HEAD)
if [ "$before" = "$after" ]; then
  echo "main is at origin/main ($after)."
else
  echo "Updated main: $before to $after ($(git -C "$root" rev-list --count "$before..$after") commits)."
fi

version=$(git -C "$root" describe --tags --always --dirty 2>/dev/null || echo dev)
# Both parts must match: a failed app install leaves the new core in place.
core=$("$prefix/bin/loam" --version 2>/dev/null | sed -n 's/^loam version //p' || true)
app=$(/usr/libexec/PlistBuddy -c "Print :LoamVersion" "$apps/Loam.app/Contents/Info.plist" 2>/dev/null || true)
if [ "$force" -eq 0 ] && [ "$core" = "$version" ] && [ "$app" = "$version" ]; then
  echo "Loam $version is installed. Nothing to do. Use --force to build again."
  exit 0
fi

# -a: from a Loam pane, Loam is an ancestor, and pgrep skips ancestors without it.
if ! pgrep -af "^$apps/Loam.app/Contents/MacOS/Loam" >/dev/null 2>&1; then
  exec "$root/scripts/install.sh" app $pass
fi

# Loam runs. Quitting Loam closes this terminal if it is a Loam pane, so the
# install runs in its own session, and this script only follows its log.
mkdir -p "$(dirname "$log")"
: > "$log"
pid=$(python3 - "$log" "$root/scripts/install.sh" app --replace-running $pass <<'EOF'
import os, sys
log, argv = sys.argv[1], sys.argv[2:]
r, w = os.pipe()
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        os.close(r)
        os.write(w, str(os.getpid()).encode())
        os.close(w)
        fd = os.open(log, os.O_WRONLY | os.O_APPEND)
        null = os.open(os.devnull, os.O_RDONLY)
        os.dup2(null, 0)
        os.dup2(fd, 1)
        os.dup2(fd, 2)
        os.execv(argv[0], argv)
    os._exit(0)
os.close(w)
print(os.read(r, 32).decode())
EOF
)
[ -n "$pid" ] || fail "Could not start the install."

echo "Building Loam $version. Loam quits when the build is done, then opens again."
echo "Do not open Loam by hand until the log says \"Reopened Loam.\""
[ -z "${LOAM_PANE_SOCKET:-}" ] || echo "This pane closes when Loam quits. The log is $log."
tail -n +1 -f "$log" &
tailpid=$!
while kill -0 "$pid" 2>/dev/null; do
  sleep 1
done
sleep 1 # let tail print the last lines
kill "$tailpid" 2>/dev/null || true
wait "$tailpid" 2>/dev/null || true
grep -q "^Installed $apps/Loam.app" "$log" || fail "The update failed. The log is $log."
