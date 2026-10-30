package testutil

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// fakeSandboxExec runs the command after -p <profile> with no sandbox. It
// writes the profile to LOAM_FAKE_SANDBOX_PROFILE first.
const fakeSandboxExec = `#!/bin/sh
if [ "$1" != -p ] || [ $# -lt 3 ]; then
	echo "fake sandbox-exec: want -p <profile> <command>" >&2
	exit 64
fi
printf '%s' "$2" > "$LOAM_FAKE_SANDBOX_PROFILE" || exit 65
shift 2
exec "$@"
`

// FakeSandbox points LOAM_SANDBOX_EXEC at a fake sandbox-exec, which runs a
// check with no sandbox, and returns the file that holds the last profile it
// got. A test of the gate then passes inside a sandbox too, where a real
// sandbox-exec cannot start.
func FakeSandbox(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "sandbox-exec")
	if err := os.WriteFile(bin, []byte(fakeSandboxExec), 0o755); err != nil {
		t.Fatal(err)
	}
	profile := filepath.Join(dir, "profile.sb")
	t.Setenv("LOAM_SANDBOX_EXEC", bin)
	t.Setenv("LOAM_FAKE_SANDBOX_PROFILE", profile)
	return profile
}

// NeedSandbox skips the test when sandbox-exec cannot apply a profile. That
// is so when the test itself runs in a sandbox, as in the Bash of a Loam run,
// because a sandbox cannot start inside another one.
func NeedSandbox(t *testing.T) {
	t.Helper()
	out, err := exec.Command("/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true").CombinedOutput()
	if err != nil {
		t.Skipf("sandbox-exec cannot apply a profile here, for example because the test runs in a sandbox: %v %s", err, out)
	}
}
