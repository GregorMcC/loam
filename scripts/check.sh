#!/bin/sh
# Run the CI checks of a change on this Mac, before you push.
#
#   scripts/check.sh [core] [app] [lint]
#
# With no job names, it picks the jobs from the files that the branch changes
# since origin/main, with the same rules as the changes job in
# .github/workflows/ci.yml. It runs each job as CI does, and stops at the
# first check that fails. It reads the tool versions from ci.yml, so they
# stay the same as CI.
#
# core: gofmt, go vet, golangci-lint, go test and govulncheck in core/.
# app: swift test in app/. With GhosttyKit built, it runs the driver tests too.
# lint: shellcheck on scripts/ and actionlint on the workflows.
set -eu

usage() {
  echo "usage: scripts/check.sh [core] [app] [lint]" >&2
}

root=$(cd "$(dirname "$0")/.." && pwd)
ci="$root/.github/workflows/ci.yml"

fail() {
  # fail MESSAGE [FIX]: print both and stop.
  echo "$1" >&2
  [ -z "${2:-}" ] || echo "Fix: $2" >&2
  exit 1
}

# version NAME prints the value of NAME in the env block of ci.yml.
version() {
  v=$(sed -n "s/^  $1: *//p" "$ci")
  [ -n "$v" ] || fail "ci.yml sets no $1."
  echo "$v"
}

core=0 app=0 lint=0
if [ $# -eq 0 ]; then
  base=$(git -C "$root" merge-base HEAD origin/main) ||
    fail "Cannot find where the branch leaves origin/main." "git fetch origin, or name the jobs."
  # The changed files of the branch, with its uncommitted and new files.
  files=$(git -C "$root" diff --name-only "$base" && git -C "$root" ls-files --others --exclude-standard)
  while IFS= read -r f; do
    case "$f" in
      .github/workflows/ci.yml) core=1 app=1 lint=1 ;;
      contract/*) core=1 app=1 ;;
      # The core tests run the scripts.
      scripts/*) core=1 lint=1 ;;
      core/* | ghostty.pin) core=1 ;;
      app/*) app=1 ;;
      # The app tests read the design docs.
      docs/*) app=1 ;;
      .github/*) lint=1 ;;
    esac
  done <<EOF
$files
EOF
else
  for job in "$@"; do
    case "$job" in
      core) core=1 ;;
      app) app=1 ;;
      lint) lint=1 ;;
      *) usage; exit 2 ;;
    esac
  done
fi

if [ "$core" = 0 ] && [ "$app" = 0 ] && [ "$lint" = 0 ]; then
  echo "The change needs no CI job."
  exit 0
fi

if [ "$core" = 1 ]; then
  echo "== core"
  cd "$root/core"
  unformatted=$(gofmt -l .)
  [ -z "$unformatted" ] || fail "gofmt changes these files:
$unformatted" "gofmt -w on them."
  go vet ./...
  go run "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(version GOLANGCI_LINT_VERSION)" run
  go test ./...
  go run "golang.org/x/vuln/cmd/govulncheck@$(version GOVULNCHECK_VERSION)" ./...
fi

if [ "$app" = 1 ]; then
  echo "== app"
  cd "$root/app"
  swift test
fi

if [ "$lint" = 1 ]; then
  echo "== lint"
  cd "$root"
  command -v shellcheck >/dev/null || fail "shellcheck is not installed." "brew install shellcheck"
  shellcheck scripts/*.sh
  go run "github.com/rhysd/actionlint/cmd/actionlint@$(version ACTIONLINT_VERSION)"
fi

echo "All checks passed."
