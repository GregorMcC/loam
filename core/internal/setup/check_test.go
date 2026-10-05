package setup_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/setup"
)

func stepMap(t *testing.T) map[string]bool {
	t.Helper()
	r, err := setup.Check("/opt/loam/bin/loam")
	if err != nil {
		t.Fatal(err)
	}
	m := map[string]bool{}
	for _, s := range r.Steps {
		m[s.ID] = s.Done
	}
	return m
}

func TestCheckReportsEachStepAndChangesNothing(t *testing.T) {
	e := newEnv(t)
	m := stepMap(t)
	if len(m) != 2 || m["mcp"] || m["trust"] {
		t.Fatalf("fresh: %v", m)
	}
	for _, c := range e.calls(t) {
		if strings.Contains(c, "mcp add") || strings.Contains(c, "mcp remove") {
			t.Fatalf("check changed state: %s", c)
		}
	}
	if _, err := os.Stat(e.plots); err == nil {
		t.Error("check made the plots folder")
	}

	if err := os.WriteFile(e.state, []byte("loam /opt/loam/bin/loam mcp"), 0o644); err != nil {
		t.Fatal(err)
	}
	if m := stepMap(t); !m["mcp"] || m["trust"] {
		t.Fatalf("mcp done: %v", m)
	}

	cfg := `{"projects":{"` + e.plots + `":{"hasTrustDialogAccepted":true}}}`
	if err := os.WriteFile(filepath.Join(os.Getenv("HOME"), ".claude.json"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
	if m := stepMap(t); !m["mcp"] || !m["trust"] {
		t.Fatalf("both done: %v", m)
	}
	r, _ := setup.Check("/opt/loam/bin/loam")
	if !r.OK {
		t.Error("OK is false with every step done")
	}

	// A different registered binary is not done.
	if err := os.WriteFile(e.state, []byte("loam /other/loam mcp"), 0o644); err != nil {
		t.Fatal(err)
	}
	if m := stepMap(t); m["mcp"] {
		t.Fatalf("other binary: %v", m)
	}
}

func TestCheckWithoutClaude(t *testing.T) {
	newEnv(t)
	t.Setenv("PATH", t.TempDir())
	r, err := setup.Check("/opt/loam/bin/loam")
	if err != nil {
		t.Fatal(err)
	}
	if r.OK || r.Steps[0].Done || r.Steps[0].Detail == "" {
		t.Fatalf("%+v", r)
	}
}
