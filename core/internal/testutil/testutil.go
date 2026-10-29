// Package testutil holds the test harness: a temp LOAM_HOME, a built loam
// binary, a fake claude that records how it was started, and a fake gh that
// answers from a made-up GitHub state.
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
// app's state.json, and LOAM_GH at a missing file, so no test runs the real
// gh. [FakeGH] replaces the missing file with a fake.
func Home(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("LOAM_HOME", dir)
	t.Setenv("LOAM_APP_STATE_DIR", filepath.Join(dir, "app-state"))
	t.Setenv("LOAM_GH", filepath.Join(dir, "no-gh"))
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
	// MCPConfig is the config of --mcp-config: the JSON, or what the file
	// held. It is empty with no --mcp-config.
	MCPConfig string `json:"mcp_config"`
}

// FakeClaude builds a fake `claude`, puts its folder first on PATH for the
// test, and returns the folder. The fake writes its argv, env, and working
// folder as JSON to the file that [FakeClaudeInvocation] reads. It then exits 0.
// It also points CLAUDE_CONFIG_DIR at a temp folder, so neither the fake, which
// writes conversation files there, nor a loam resume, which reads them, reaches
// the real ~/.claude. Call it after [Home] and before you run a command that
// starts claude.
func FakeClaude(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	build(t, "github.com/GregorMcC/loam/core/internal/testutil/fakeclaude", filepath.Join(dir, "claude"))
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("LOAM_FAKE_CLAUDE_OUT", filepath.Join(dir, "invocation.json"))
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	return dir
}

// FakeClaudePrint makes a -p call of the fake claude print text, as
// claude -p --output-format json prints its result.
func FakeClaudePrint(t *testing.T, text string) {
	t.Helper()
	file := filepath.Join(t.TempDir(), "print.json")
	if err := os.WriteFile(file, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LOAM_FAKE_CLAUDE_PRINT", file)
}

// FakeClaudePrintFor makes a -p call of the fake claude whose --json-schema
// holds schemaText print text, in place of the text of [FakeClaudePrint].
// Each schemaText gets its own text, and a later call for the same
// schemaText replaces it.
func FakeClaudePrintFor(t *testing.T, schemaText, text string) {
	t.Helper()
	file := filepath.Join(t.TempDir(), "print.json")
	if err := os.WriteFile(file, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{}
	if s := os.Getenv("LOAM_FAKE_CLAUDE_PRINTS"); s != "" {
		if err := json.Unmarshal([]byte(s), &files); err != nil {
			t.Fatal(err)
		}
	}
	files[schemaText] = file
	b, err := json.Marshal(files)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("LOAM_FAKE_CLAUDE_PRINTS", string(b))
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

// FakeClaudeCalls returns the argv of each call of the fake claude, oldest
// first.
func FakeClaudeCalls(t *testing.T) [][]string {
	t.Helper()
	b, err := os.ReadFile(os.Getenv("LOAM_FAKE_CLAUDE_OUT") + ".log")
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var calls [][]string
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		var args []string
		if err := json.Unmarshal([]byte(line), &args); err != nil {
			t.Fatal(err)
		}
		calls = append(calls, args)
	}
	return calls
}

// FakeGH builds a fake `gh` and points LOAM_GH at it for the test. The fake
// answers each GraphQL query from the GitHub state in state (JSON, see
// internal/testutil/fakegh) and logs each call for [FakeGHCalls]. A merge, an
// update, or a branch delete changes the state. It returns the state file, so
// a test can write a new state. Set LOAM_FAKE_GH_FAIL to make each call fail.
// Call it after [Home].
func FakeGH(t *testing.T, state string) string {
	t.Helper()
	dir := t.TempDir()
	gh := filepath.Join(dir, "gh")
	build(t, "github.com/GregorMcC/loam/core/internal/testutil/fakegh", gh)
	file := filepath.Join(dir, "state.json")
	if err := os.WriteFile(file, []byte(state), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LOAM_GH", gh)
	t.Setenv("LOAM_FAKE_GH_STATE", file)
	t.Setenv("LOAM_FAKE_GH_LOG", filepath.Join(dir, "calls.jsonl"))
	return file
}

// GHCall is one call that the fake gh logged.
type GHCall struct {
	Args      []string       `json:"args"`
	Variables map[string]any `json:"variables"`
}

// FakeGHCalls returns the calls that the fake gh logged, oldest first.
func FakeGHCalls(t *testing.T) []GHCall {
	t.Helper()
	b, err := os.ReadFile(os.Getenv("LOAM_FAKE_GH_LOG"))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var calls []GHCall
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		var c GHCall
		if err := json.Unmarshal([]byte(line), &c); err != nil {
			t.Fatal(err)
		}
		calls = append(calls, c)
	}
	return calls
}
