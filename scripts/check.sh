#!/bin/sh
# Run the CI checks of a change on this Mac, before you push.
#
#   scripts/check.sh [core] [app] [lint]
#
# With no job names, it picks the jobs from the files that the branch changes
# since origin/main, with the rules of the changes job in
# .github/workflows/ci.yml, and it always runs lint, as CI does. It runs each
# check of each job, and at the end it lists the checks that failed. It reads
# the tool versions from ci.yml, so they stay the same as CI.
#
# core: gofmt, go vet, golangci-lint, go test and govulncheck in core/.
# app: swift test in app/. With GhosttyKit built, it also builds the app with
# GhosttyKit and runs the driver tests, which CI does not run (TAS-57).
# lint: shellcheck on scripts/ and actionlint on the workflows.
#
# In a sandbox, such as the sandbox of a Loam run, it passes --disable-sandbox
# to swift test, and it skips govulncheck when vuln.go.dev is out of reach.
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

# version NAME prints the value of NAME in the env block of ci.yml, without
# quotes or a comment.
version() {
  v=$(sed -n "s/^  $1: *[\"']\{0,1\}\([^\"' #]*\).*/\1/p" "$ci")
  [ -n "$v" ] || fail "ci.yml sets no $1." "Change version() in scripts/check.sh to match ci.yml."
  echo "$v"
}

core=0 app=0 lint=0
if [ $# -eq 0 ]; then
  lint=1
  base=$(git -C "$root" merge-base HEAD origin/main) ||
    fail "Cannot find where the branch leaves origin/main." "git fetch origin, or name the jobs."
  # The changed files of the branch, with its uncommitted and new files. With
  # --no-renames, a rename gives both paths, as the files API gives CI.
  files=$(git -C "$root" -c core.quotePath=false diff --name-only --no-renames "$base" &&
    git -C "$root" -c core.quotePath=false ls-files --others --exclude-standard)
  while IFS= read -r f; do
    case "$f" in
      .github/workflows/ci.yml) core=1 app=1 ;;
      contract/*) core=1 app=1 ;;
      # CI builds GhosttyKit again for these, and the app job checks the pin.
      scripts/build-ghosttykit.sh | ghostty.pin) core=1 app=1 ;;
      # The core tests run the scripts.
      core/* | scripts/*) core=1 ;;
      # build-icon.sh reads app/Resources.
      app/Resources/*) core=1 app=1 ;;
      app/*) app=1 ;;
      # The app tests read the design docs.
      docs/*) app=1 ;;
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

# Read the versions and look for the tools first, so a missing tool stops the
# script before the long jobs run.
if [ "$core" = 1 ] || [ "$lint" = 1 ]; then
  command -v go >/dev/null || fail "go is not installed." "brew install go"
fi
if [ "$core" = 1 ]; then
  golangci_lint=$(version GOLANGCI_LINT_VERSION)
  govulncheck=$(version GOVULNCHECK_VERSION)
fi
if [ "$app" = 1 ]; then
  xcode=$(version XCODE)
  if [ -d "$xcode" ]; then
    DEVELOPER_DIR="$xcode/Contents/Developer"
    export DEVELOPER_DIR
  else
    echo "$xcode is not here, so swift uses the Xcode that xcode-select gives."
  fi
  # /usr/bin/swift is a shim that is there with no Xcode, so ask xcrun.
  xcrun --find swift >/dev/null 2>&1 || fail "swift is not installed." "Install Xcode, as the README says."
fi
if [ "$lint" = 1 ]; then
  actionlint=$(version ACTIONLINT_VERSION)
  command -v shellcheck >/dev/null || fail "shellcheck is not installed." "brew install shellcheck"
fi

# A sandbox cannot start inside another one, such as the sandbox of a Loam
# run or of its gate. SwiftPM sandboxes its manifest, and govulncheck reads
# vuln.go.dev, which the gate cannot reach.
sandboxed=0
if [ -x /usr/bin/sandbox-exec ] && ! /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then
  sandboxed=1
fi

failed=""

# check NAME COMMAND...: run a check, and note its name when it fails.
check() {
  name=$1
  shift
  echo "-- $name"
  "$@" || failed="$failed $name"
}

gofmt_clean() {
  unformatted=$(gofmt -l .)
  [ -z "$unformatted" ] && return
  echo "gofmt changes these files. Run gofmt -w on them:"
  echo "$unformatted"
  return 1
}

govulncheck_run() {
  if [ "$sandboxed" = 1 ] && ! curl -fsS --max-time 10 -o /dev/null https://vuln.go.dev/index/db.json; then
    echo "The sandbox does not reach vuln.go.dev, so govulncheck does not run here. CI runs it."
    return
  fi
  go run "golang.org/x/vuln/cmd/govulncheck@$govulncheck" ./...
}

# CI runs the release binary of golangci-lint. A source build can lint
# differently, so the script uses a golangci-lint of the same version when
# one is on the PATH.
golangci_lint() {
  if command -v golangci-lint >/dev/null &&
    [ "v$(golangci-lint version --short 2>/dev/null)" = "$golangci_lint" ]; then
    golangci-lint run
    return
  fi
  echo "No golangci-lint $golangci_lint on the PATH, so it builds one from source. Its results can differ from CI."
  go run "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$golangci_lint" run
}

if [ "$core" = 1 ]; then
  echo "== core"
  cd "$root/core"
  check gofmt gofmt_clean
  check "go vet" go vet ./...
  check golangci-lint golangci_lint
  check "go test" go test ./...
  check govulncheck govulncheck_run
fi

if [ "$app" = 1 ]; then
  echo "== app"
  cd "$root/app"
  # Package.swift builds the terminal and the driver only when app/vendor has
  # GhosttyKit, and SwiftPM caches the manifest that reads it.
  # build-ghosttykit.sh links app/vendor to a cache folder named for the
  # pinned commit.
  pin=$(sed -n 's/^GHOSTTY_COMMIT=//p' "$root/ghostty.pin")
  if ! built=$(cd vendor/GhosttyKit.xcframework 2>/dev/null && pwd -P); then
    echo "GhosttyKit is not built, so swift test skips the driver tests."
  else
    case "$built" in
      */"$pin"/*) ;;
      *) fail "GhosttyKit is not built for the commit in ghostty.pin." "scripts/build-ghosttykit.sh" ;;
    esac
  fi
  if [ "$sandboxed" = 1 ]; then
    check "swift test" swift test --manifest-cache none --disable-sandbox
  else
    check "swift test" swift test --manifest-cache none
  fi
fi

if [ "$lint" = 1 ]; then
  echo "== lint"
  cd "$root"
  check shellcheck shellcheck scripts/*.sh
  check actionlint go run "github.com/rhysd/actionlint/cmd/actionlint@$actionlint"
fi

if [ -n "$failed" ]; then
  echo "These checks failed:$failed" >&2
  exit 1
fi
echo "All checks passed."
