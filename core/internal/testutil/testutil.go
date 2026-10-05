// Package testutil holds the test harness: a temp LOAM_HOME, a built loam
// binary, and a fake claude that records how it was started.
package testutil

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Home sets LOAM_HOME to a new temp folder for the test and returns it. It
// also points LOAM_APP_STATE_DIR at an empty folder, so no test reads the real
// app's state.json.
func Home(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("LOAM_HOME", dir)
	t.Setenv("LOAM_APP_STATE_DIR", filepath.Join(dir, "app-state"))
	return dir
}

// goCaches pins GOMODCACHE and GOCACHE for the builds, read once before any
// test moves HOME. A test that moves HOME to a temp folder would otherwise
// download every module again into that folder, and the read-only module
// files would then stop the temp folder cleanup.
var goCaches = func() []string {
	out, err := exec.Command("go", "env", "GOMODCACHE", "GOCACHE").Output()
	if err != nil {
		return nil
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) != 2 {
		return nil
	}
	return []string{"GOMODCACHE=" + lines[0], "GOCACHE=" + lines[1]}
}()

func build(t *testing.T, pkg, out string) {
	t.Helper()
	cmd := exec.Command("go", "build", "-o", out, pkg)
	cmd.Env = append(os.Environ(), goCaches...)
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build %s: %v\n%s", pkg, err, b)
	}
}

// BuildLoam builds cmd/loam into a temp folder and returns the binary path.
// Run it with LOAM_HOME set by [Home] to test against a temp store.
func BuildLoam(t *testing.T) string {
	t.Helper()
	out := filepath.Join(t.TempDir(), "loam")
	build(t, "github.com/GregorMcC/loam/core/cmd/loam", out)
	return out
}

// Invocation is what the fake claude recorded about one run.
type Invocation struct {
	Args []string          `json:"args"`
	Env  map[string]string `json:"env"`
	Cwd  string            `json:"cwd"`
}

// FakeClaude builds a fake `claude`, puts its folder first on PATH for the
// test, and returns the folder. The fake writes its argv, env, and working
// folder as JSON to the file that [FakeClaudeInvocation] reads. It then exits 0.
// Call it after [Home] and before you run a command that starts claude.
func FakeClaude(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	build(t, "github.com/GregorMcC/loam/core/internal/testutil/fakeclaude", filepath.Join(dir, "claude"))
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("LOAM_FAKE_CLAUDE_OUT", filepath.Join(dir, "invocation.json"))
	return dir
}

// FakeClaudeInvocation returns what the fake claude recorded. It fails the
// test if the fake did not run.
func FakeClaudeInvocation(t *testing.T) Invocation {
	t.Helper()
	b, err := os.ReadFile(os.Getenv("LOAM_FAKE_CLAUDE_OUT"))
	if err != nil {
		t.Fatalf("the fake claude did not run: %v", err)
	}
	var inv Invocation
	if err := json.Unmarshal(b, &inv); err != nil {
		t.Fatal(err)
	}
	return inv
}
