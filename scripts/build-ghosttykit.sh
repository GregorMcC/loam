#!/bin/bash
# Build GhosttyKit.xcframework and the Ghostty resources for the commit in
# ghostty.pin, once per commit.
#
#   scripts/build-ghosttykit.sh
#
# The cache is $LOAM_CACHE (default ~/Library/Caches/Loam). It holds Zig, the
# ghostty source, and per commit one xcframework and one share folder (the
# resources: share/ghostty with themes and shell integration, and
# share/terminfo). Zig never goes on PATH. The script links
# app/vendor/GhosttyKit.xcframework and app/vendor/ghostty-share (or the same
# names in $LOAM_VENDOR) to the cache.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
. "$root/ghostty.pin"

cache="${LOAM_CACHE:-$HOME/Library/Caches/Loam}"
vendor="${LOAM_VENDOR:-$root/app/vendor}"
final="$cache/ghosttykit/$GHOSTTY_COMMIT/GhosttyKit.xcframework"
share="$cache/ghosttykit/$GHOSTTY_COMMIT/share"

link_vendor() {
  mkdir -p "$vendor"
  rm -rf "$vendor/GhosttyKit.xcframework" "$vendor/ghostty-share"
  ln -s "$final" "$vendor/GhosttyKit.xcframework"
  ln -s "$share" "$vendor/ghostty-share"
  echo "Linked $vendor/GhosttyKit.xcframework and $vendor/ghostty-share"
}

if [ -d "$final" ] && [ -d "$share/ghostty" ] && [ -d "$share/terminfo" ]; then
  echo "GhosttyKit for ${GHOSTTY_COMMIT:0:8} is cached."
  link_vendor
  exit 0
fi

if [ "$(uname -m)" != arm64 ]; then
  echo "The Zig pin is for Apple silicon (arm64). This Mac is $(uname -m)." >&2
  echo "Fix: add the Zig SHA-256 for this CPU to ghostty.pin and this script." >&2
  exit 1
fi

mkdir -p "$cache"
zig_dir="$cache/zig-$ZIG_VERSION"
src_dir="$cache/ghostty-src"
work="$cache/ghosttykit/.build-$GHOSTTY_COMMIT"

# 1. Zig, in the cache, checked against the pinned SHA-256.
if [ ! -x "$zig_dir/zig" ]; then
  echo "Downloading Zig $ZIG_VERSION..."
  tarball="$cache/zig.tar.xz"
  if ! curl -fsSL -o "$tarball" "https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-macos-$ZIG_VERSION.tar.xz"; then
    rm -f "$tarball"
    echo "The Zig download failed. Check the network, then run this script again." >&2
    exit 1
  fi
  if ! echo "$ZIG_SHA256  $tarball" | shasum -a 256 -c - >/dev/null; then
    rm -f "$tarball"
    echo "The Zig download does not match the SHA-256 in ghostty.pin." >&2
    exit 1
  fi
  rm -rf "$zig_dir.tmp"
  mkdir -p "$zig_dir.tmp"
  tar -xJf "$tarball" -C "$zig_dir.tmp" --strip-components=1
  rm -f "$tarball"
  mv "$zig_dir.tmp" "$zig_dir"
fi

# 2. The ghostty source at the pinned commit.
if [ ! -d "$src_dir/.git" ]; then
  git init -q "$src_dir"
  git -C "$src_dir" remote add origin https://github.com/ghostty-org/ghostty.git
fi
if [ "$(git -C "$src_dir" rev-parse HEAD 2>/dev/null || true)" != "$GHOSTTY_COMMIT" ]; then
  echo "Fetching ghostty $GHOSTTY_COMMIT..."
  git -C "$src_dir" fetch -q --depth 1 origin "$GHOSTTY_COMMIT"
  git -C "$src_dir" checkout -q -f FETCH_HEAD
fi

# 3. Build the xcframework.
echo "Building GhosttyKit. This takes a few minutes the first time."
rm -rf "$work"
mkdir -p "$work"
(cd "$src_dir" && "$zig_dir/zig" build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-macos-app=false \
  -Dsentry=false \
  --prefix "$work/out")
cp -R "$src_dir/macos/GhosttyKit.xcframework" "$work/GhosttyKit.xcframework"

# 4. Give Swift a module map it can import.
find "$work/GhosttyKit.xcframework" -path '*/Headers/module.modulemap' -print0 |
  while IFS= read -r -d '' modulemap; do
    printf 'module GhosttyKit {\n    header "ghostty.h"\n    export *\n}\n' > "$modulemap"
  done

# 5. Keep the resources: the xcframework build installs them in the prefix.
mkdir -p "$work/share"
mv "$work/out/share/ghostty" "$work/out/share/terminfo" "$work/share/"

# 6. Publish each part with one rename, so a stopped build never leaves a half
# cache. A cache from before the resources keeps its xcframework.
mkdir -p "$(dirname "$final")"
[ -d "$final" ] || mv "$work/GhosttyKit.xcframework" "$final"
rm -rf "$share"
mv "$work/share" "$share"
rm -rf "$work"
echo "Built $final"
link_vendor
