#!/bin/sh
# Build a Loam release and publish it on GitHub.
#
#   scripts/release.sh TAG [--dry-run]
#
# TAG is vMAJOR.MINOR.PATCH. The script tags main, builds the loam CLI and
# Loam.app with the CLI inside, and signs both with the "Loam Local Signing"
# certificate. It zips the app as Loam.zip with a SHA-256 file, pushes the tag,
# and creates the GitHub release. scripts/install-release.sh installs it.
#
# Every release must have the same certificate: macOS keeps Loam's folder
# permissions only while the signature stays the same. Keep a backup of the
# certificate (Keychain Access > export "Loam Local Signing" as .p12).
#
# --dry-run builds and zips on any branch, then deletes the local tag. It
# pushes nothing, and it prints the folder that holds Loam.zip.
set -eu

usage() {
  echo "usage: scripts/release.sh vMAJOR.MINOR.PATCH [--dry-run]" >&2
}

# install-release.sh pins the same certificate. A test checks that they match.
cert=72E22E0E1CDB829CFF9A4DE5E84804F49B5D6E18
requirement="identifier \"dev.loam.Loam\" and certificate leaf = H\"72e22e0e1cdb829cff9a4de5e84804f49b5d6e18\""

tag="${1:-}"
[ $# -gt 0 ] && shift
dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    *) usage; exit 2 ;;
  esac
done
printf '%s\n' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || { usage; exit 2; }

root=$(cd "$(dirname "$0")/.." && pwd)

fail() {
  # fail MESSAGE [FIX]: print both and stop.
  echo "$1" >&2
  [ -z "${2:-}" ] || echo "Fix: $2" >&2
  exit 1
}

security find-identity -v -p codesigning 2>/dev/null | grep -q "$cert" ||
  fail "The \"Loam Local Signing\" certificate ($cert) is not in your keychain. Releases must use it." \
    "import it from your .p12 backup with Keychain Access, then trust it for code signing"

if [ "$dry" -eq 0 ]; then
  command -v gh >/dev/null 2>&1 || fail "gh is not installed." "brew install gh"
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in." "gh auth login"
  branch=$(git -C "$root" branch --show-current)
  [ "$branch" = main ] || fail "The checkout is on ${branch:-a detached HEAD}, not main." "git -C \"$root\" switch main"
  [ -z "$(git -C "$root" status --porcelain --untracked-files=no)" ] ||
    fail "The checkout has uncommitted changes." "commit or stash them, then run this script again"
  git -C "$root" fetch --quiet origin || fail "Could not fetch from origin."
  [ "$(git -C "$root" rev-parse HEAD)" = "$(git -C "$root" rev-parse origin/main)" ] ||
    fail "main is not at origin/main." "push or pull main, then run this script again"
  [ -z "$(git -C "$root" ls-remote --tags origin "refs/tags/$tag")" ] || fail "origin already has the tag $tag."
fi
! git -C "$root" rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "The tag $tag already exists here." "git tag -d $tag"

work=$(mktemp -d)
published=0
# Until the release is published, a failure deletes the local tag.
cleanup() {
  [ "$published" -eq 1 ] || git -C "$root" tag -d "$tag" >/dev/null 2>&1 || true
  [ "$dry" -eq 1 ] || rm -rf "$work"
}
trap cleanup EXIT

# The tag comes first, so git describe gives TAG to the CLI and the app.
git -C "$root" tag -a "$tag" -m "Loam $tag"
LOAM_PREFIX="$work/prefix" "$root/scripts/install.sh" core
"$root/scripts/build-app.sh" "$work/out" --identity "$cert" --cli "$work/prefix/bin/loam"

app="$work/out/Loam.app"
codesign --verify --deep --strict -R="$requirement" "$app" || fail "Loam.app does not meet the release requirement."
v=$("$app/Contents/Helpers/loam" version | sed -n 's/^loam version //p')
[ "$v" = "$tag" ] || fail "The loam CLI says $v, not $tag."
ditto -c -k --keepParent "$app" "$work/Loam.zip"
(cd "$work" && shasum -a 256 Loam.zip > Loam.zip.sha256)

if [ "$dry" -eq 1 ]; then
  echo "Dry run: built $work/Loam.zip ($tag). Nothing is pushed."
  echo "Try it: LOAM_RELEASES_URL=file://$work/releases sh scripts/install-release.sh --apps-dir /tmp/apps --prefix /tmp/prefix"
  mkdir -p "$work/releases/latest/download"
  cp "$work/Loam.zip" "$work/Loam.zip.sha256" "$work/releases/latest/download/"
  exit 0
fi

git -C "$root" push --quiet origin "refs/tags/$tag"
gh release create "$tag" "$work/Loam.zip" "$work/Loam.zip.sha256" \
  --repo GregorMcC/loam --verify-tag --title "Loam $tag" --generate-notes ||
  fail "Could not create the GitHub release. origin has the tag $tag." \
    "git -C \"$root\" push origin :refs/tags/$tag, then run this script again"
published=1
echo "Published Loam $tag."
echo "Install or update: curl -fsSL https://raw.githubusercontent.com/GregorMcC/loam/main/scripts/install-release.sh | sh"
