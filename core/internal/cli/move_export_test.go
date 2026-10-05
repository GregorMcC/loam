package cli_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func listNames(e *env) string {
	var l []store.PlotSummary
	if err := json.Unmarshal([]byte(e.ok("", "list", "--json")), &l); err != nil {
		e.t.Fatal(err)
	}
	var n []string
	for _, p := range l {
		n = append(n, p.Name)
	}
	return strings.Join(n, ",")
}

func TestMoveCommand(t *testing.T) {
	e := newEnv(t)
	for _, n := range []string{"Alpha", "Beta", "Gamma"} {
		e.newPlot(n)
	}
	e.ok("", "move", "Gamma", "1")
	if got := listNames(e); got != "Gamma,Alpha,Beta" {
		t.Fatalf("after move to start: %s", got)
	}
	e.ok("", "move", "gamma", "3")
	if got := listNames(e); got != "Alpha,Beta,Gamma" {
		t.Fatalf("after move to end: %s", got)
	}
	e.ok("", "move", "Gamma", "2")
	if got := listNames(e); got != "Alpha,Gamma,Beta" {
		t.Fatalf("after move to middle: %s", got)
	}
	out := e.ok("", "move", "Beta", "1", "--json")
	var r struct {
		Plot     string `json:"plot"`
		Position int    `json:"position"`
	}
	if err := json.Unmarshal([]byte(out), &r); err != nil || r.Position != 1 || r.Plot == "" {
		t.Fatalf("json %q: %v", out, err)
	}
	// No change log entry for any move.
	var x struct {
		Changes []store.ChangeRecord `json:"changes"`
	}
	if err := json.Unmarshal([]byte(e.ok("", "export", "--changes")), &x); err != nil || len(x.Changes) != 3 {
		t.Fatalf("changes %d (err %v), want the 3 creates", len(x.Changes), err)
	}
}

func TestMoveErrors(t *testing.T) {
	e := newEnv(t)
	e.newPlot("Alpha")
	for _, args := range [][]string{{"move", "Alpha", "0"}, {"move", "Alpha", "2"}, {"move", "Alpha", "x"}} {
		if code, _, _ := e.fail(args...); code != 2 {
			t.Errorf("%v: exit %d, want 2", args, code)
		}
	}
	e.failJSON(14, "unknown_plot", "move", "Nope", "1")
}

func TestExport(t *testing.T) {
	e := newEnv(t)
	a := e.newPlot("Alpha")
	e.newPlot("Beta")
	e.ok("", "set", "Alpha", "what", "new what")
	e.ok("", "link", "add", "Alpha", "Docs", "https://example.com")

	var x struct {
		Plots   []store.Plot         `json:"plots"`
		Changes []store.ChangeRecord `json:"changes"`
	}
	out := e.ok("", "export")
	if err := json.Unmarshal([]byte(out), &x); err != nil {
		t.Fatal(err)
	}
	if len(x.Plots) != 2 || x.Plots[0].ID != a.ID || x.Plots[0].What != "new what" || len(x.Plots[0].Links) != 1 {
		t.Fatalf("plots %+v", x.Plots)
	}
	if strings.Contains(out, `"changes"`) {
		t.Error("changes present without --changes")
	}

	out = e.ok("", "export", "--changes")
	x.Changes = nil
	if err := json.Unmarshal([]byte(out), &x); err != nil {
		t.Fatal(err)
	}
	if len(x.Changes) != 4 {
		t.Fatalf("changes %d, want 4", len(x.Changes))
	}
	for i := 1; i < len(x.Changes); i++ {
		if x.Changes[i].ID <= x.Changes[i-1].ID {
			t.Error("changes not oldest first")
		}
	}
}

func TestExportEmpty(t *testing.T) {
	e := newEnv(t)
	out := e.ok("", "export", "--changes")
	if !strings.Contains(out, `"plots": []`) || !strings.Contains(out, `"changes": []`) {
		t.Fatalf("%s", out)
	}
}

type checkResult struct {
	OK    bool `json:"ok"`
	Steps []struct {
		ID     string `json:"id"`
		Done   bool   `json:"done"`
		Detail string `json:"detail"`
	} `json:"steps"`
}

func (e *env) check() (checkResult, map[string]bool) {
	e.t.Helper()
	var r checkResult
	if err := json.Unmarshal([]byte(e.ok("", "setup", "--check", "--json")), &r); err != nil {
		e.t.Fatal(err)
	}
	m := map[string]bool{}
	for _, s := range r.Steps {
		m[s.ID] = s.Done
	}
	return r, m
}

func TestSetupCheckJSON(t *testing.T) {
	e := newEnv(t)
	h := t.TempDir()
	t.Setenv("HOME", h)
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	dir := t.TempDir()
	state := filepath.Join(dir, "state")
	log := filepath.Join(dir, "log")
	script := "#!/bin/sh\necho \"$*\" >> " + log + "\n" +
		"[ \"$1 $2\" = \"mcp get\" ] && [ -f " + state + " ] && { cat " + state + "; exit 0; }\nexit 1\n"
	if err := os.WriteFile(filepath.Join(dir, "claude"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	r, m := e.check()
	if r.OK || len(m) != 2 || m["mcp"] || m["trust"] {
		t.Fatalf("nothing done: %+v", r)
	}
	if _, err := os.Stat(filepath.Join(e.home, "plots")); err == nil {
		t.Error("check made the plots folder")
	}

	// Register the binary that the test runs.
	bin, _ := filepath.EvalSymlinks(e.bin)
	if err := os.WriteFile(state, []byte("loam "+bin+" mcp"), 0o644); err != nil {
		t.Fatal(err)
	}
	if r, m = e.check(); r.OK || !m["mcp"] || m["trust"] {
		t.Fatalf("mcp done: %+v", r)
	}

	cfg := `{"projects":{"` + filepath.Join(e.home, "plots") + `":{"hasTrustDialogAccepted":true}}}`
	if err := os.WriteFile(filepath.Join(h, ".claude.json"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
	if r, m = e.check(); !r.OK || !m["mcp"] || !m["trust"] {
		t.Fatalf("both done: %+v", r)
	}

	b, _ := os.ReadFile(log)
	for _, l := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(l, "mcp add") || strings.HasPrefix(l, "mcp remove") {
			t.Errorf("check changed claude: %s", l)
		}
	}
}

func TestSetupCheckText(t *testing.T) {
	e := newEnv(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	t.Setenv("PATH", t.TempDir())
	out := e.ok("", "setup", "--check")
	if !strings.Contains(out, "mcp: not done") || !strings.Contains(out, "trust: not done") {
		t.Fatalf("%s", out)
	}
}
