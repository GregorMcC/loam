#!/bin/sh
# Remove the Loam binary, Loam.app, and the MCP registration.
#
#   scripts/uninstall.sh [--prefix DIR] [--apps-dir DIR] [--purge]
#
# DIR defaults to $LOAM_PREFIX, else ~/.local. Loam.app comes from /Applications
# unless you pass --apps-dir. The store (LOAM_HOME, default
# ~/.loam) stays unless you pass --purge.
set -eu

prefix="${LOAM_PREFIX:-$HOME/.local}"
apps="${LOAM_APPS_DIR:-/Applications}"
purge=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || { echo "--prefix needs a folder" >&2; exit 2; }; prefix="$2"; shift 2 ;;
    --apps-dir) [ $# -ge 2 ] || { echo "--apps-dir needs a folder" >&2; exit 2; }; apps="$2"; shift 2 ;;
    --purge) purge=1; shift ;;
    *) echo "usage: scripts/uninstall.sh [--prefix DIR] [--apps-dir DIR] [--purge]" >&2; exit 2 ;;
  esac
done

# claude from PATH, else from the folders Claude Code installs to. A login
# shell that is not interactive does not read .zshrc, where the installer
# adds ~/.local/bin to PATH.
claude=$(command -v claude 2>/dev/null || true)
for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude"; do
  [ -z "$claude" ] && [ -f "$c" ] && [ -x "$c" ] && claude="$c"
done

if [ -n "$claude" ]; then
  if "$claude" mcp get loam >/dev/null 2>&1; then
    "$claude" mcp remove --scope user loam && echo "Removed the MCP registration."
  else
    echo "No MCP registration found."
  fi
else
  echo "claude is not on PATH. Skipped the MCP registration." >&2
fi

if [ -e "$prefix/bin/loam" ]; then
  rm -f "$prefix/bin/loam"
  echo "Removed $prefix/bin/loam."
else
  echo "No binary at $prefix/bin/loam."
fi

if [ -e "$apps/Loam.app" ]; then
  # -a: from a Loam pane, Loam is an ancestor, and pgrep skips ancestors without it.
  if pgrep -af "^$apps/Loam.app/Contents/MacOS/Loam" >/dev/null 2>&1; then
    echo "Loam is running. Quit Loam, then run this script again." >&2
    exit 1
  fi
  rm -rf "$apps/Loam.app"
  echo "Removed $apps/Loam.app."
else
  echo "No app at $apps/Loam.app."
fi

home="${LOAM_HOME:-$HOME/.loam}"
if [ "$purge" -eq 1 ]; then
  case "$home" in
    /|"$HOME"|"$HOME"/|[!/]*) echo "Refusing to purge $home. Set LOAM_HOME to an absolute loam folder." >&2; exit 1 ;;
  esac
  rm -rf "$home"
  echo "Removed $home."
else
  echo "Kept $home. Pass --purge to remove it."
fi
