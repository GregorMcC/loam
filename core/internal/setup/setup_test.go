package setup_test

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/setup"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// Stateful fake claude: it logs every call, and "mcp get" succeeds after "mcp add".
const script = `#!/bin/sh
echo "$PWD|$*" >> "$FAKE_LOG"
case "$1 $2" in
"mcp get") [ -f "$FAKE_STATE" ] && { cat "$FAKE_STATE"; exit 0; }; exit 1;;
"mcp add") shift; shift; echo "$*" > "$FAKE_STATE"; exit 0;;
"mcp remove") rm -f "$FAKE_STATE"; exit 0;;
esac
exit 0
`

type env struct {
	home, log, state, plots string
}

func newEnv(t *testing.T) env {
	t.Helper()
	e := env{home: testutil.Home(t)}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "claude"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	e.log = filepath.Join(dir, "log")
	e.state = filepath.Join(dir, "state")
	t.Setenv("FAKE_LOG", e.log)
	t.Setenv("FAKE_STATE", e.state)
	t.Setenv("HOME", t.TempDir())
	e.plots = filepath.Join(e.home, "plots")
	return e
}

func (e env) calls(t *testing.T) []string {
	b, _ := os.ReadFile(e.log)
	s := strings.TrimSpace(string(b))
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

func run(t *testing.T, in string, yes bool) (string, error) {
	t.Helper()
	var out bytes.Buffer
	err := setup.Run(setup.Options{
		Binary: "/opt/loam/bin/loam",
		Yes:    yes,
		In:     strings.NewReader(in),
		Out:    &out,
	})
	return out.String(), err
}

func TestRegistersMCPAtUserScopeWithAbsolutePath(t *testing.T) {
	e := newEnv(t)
	if _, err := run(t, "", true); err != nil {
		t.Fatal(err)
	}
	var add string
	for _, c := range e.calls(t) {
		if strings.Contains(c, "|mcp add") {
			add = c
		}
	}
	want := "mcp add --scope user loam -- /opt/loam/bin/loam mcp"
	if !strings.HasSuffix(add, "|"+want) {
		t.Fatalf("add call %q, want suffix %q", add, want)
	}
}

func TestStartsClaudeInPlotsFolder(t *testing.T) {
	e := newEnv(t)
	if _, err := run(t, "", true); err != nil {
		t.Fatal(err)
	}
	resolved, _ := filepath.EvalSymlinks(e.plots)
	var found bool
	for _, c := range e.calls(t) {
		cwd, args, _ := strings.Cut(c, "|")
		if args == "" && (cwd == e.plots || cwd == resolved) {
			found = true
		}
	}
	if !found {
		t.Fatalf("no bare claude run in %s: %v", e.plots, e.calls(t))
	}
}

func TestPrintsReadToolAllowRules(t *testing.T) {
	newEnv(t)
	out, err := run(t, "", true)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range []string{"mcp__loam__list_plots", "mcp__loam__get_plot", "mcp__loam__get_changes"} {
		if !strings.Contains(out, r) {
			t.Errorf("output lacks %s:\n%s", r, out)
		}
	}
	if strings.Contains(out, "mcp__loam__add_link") {
		t.Error("write tools must not be in the allow rules")
	}
}

func TestSecondRunChangesNothing(t *testing.T) {
	e := newEnv(t)
	if _, err := run(t, "", true); err != nil {
		t.Fatal(err)
	}
	// Claude records trust in its own config after the first run.
	cfg := `{"projects":{"` + e.plots + `":{"hasTrustDialogAccepted":true}}}`
	if err := os.WriteFile(filepath.Join(os.Getenv("HOME"), ".claude.json"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
	before := len(e.calls(t))
	out, err := run(t, "", true)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range e.calls(t)[before:] {
		if strings.Contains(c, "mcp add") || strings.HasSuffix(c, "|") {
			t.Errorf("second run did something: %s", c)
		}
	}
	if !strings.Contains(out, "done") {
		t.Errorf("output should report done steps:\n%s", out)
	}
}

func TestReRegistersWhenPathDiffers(t *testing.T) {
	e := newEnv(t)
	if err := os.WriteFile(e.state, []byte("--scope user loam -- /old/loam mcp"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := run(t, "", true); err != nil {
		t.Fatal(err)
	}
	all := strings.Join(e.calls(t), "\n")
	if !strings.Contains(all, "mcp remove --scope user loam") || !strings.Contains(all, "-- /opt/loam/bin/loam mcp") {
		t.Fatalf("calls:\n%s", all)
	}
}

func TestReRegistersWhenPathIsOnlyAPrefix(t *testing.T) {
	e := newEnv(t)
	if err := os.WriteFile(e.state, []byte("--scope user loam -- /opt/loam/bin/loam-old mcp"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := run(t, "", true); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.Join(e.calls(t), "\n"), "mcp remove") {
		t.Fatal("did not re-register")
	}
}

func TestAnswerNoSkipsTheStep(t *testing.T) {
	e := newEnv(t)
	if _, err := run(t, "n\nn\n", false); err != nil {
		t.Fatal(err)
	}
	for _, c := range e.calls(t) {
		if strings.Contains(c, "mcp add") || strings.HasSuffix(c, "|") {
			t.Errorf("step ran after no: %s", c)
		}
	}
}

func TestAnswerYesRunsTheStep(t *testing.T) {
	e := newEnv(t)
	if _, err := run(t, "y\ny\n", false); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(e.state); err != nil {
		t.Fatal("mcp add did not run")
	}
}

func TestMissingClaudeFailsWithFix(t *testing.T) {
	newEnv(t)
	t.Setenv("PATH", t.TempDir())
	_, err := run(t, "", true)
	if err == nil || !strings.Contains(err.Error(), "claude") {
		t.Fatalf("err %v", err)
	}
}
