package mcpserver_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func TestGetPlotReturnsLinkKindAndExists(t *testing.T) {
	e := setup(t, opts{})
	home := t.TempDir()
	t.Setenv("HOME", home)
	vault := filepath.Join(home, "vault")
	cfgDir := filepath.Join(home, "Library", "Application Support", "obsidian")
	for _, d := range []string{vault, cfgDir, filepath.Join(home, "plain")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	cfg := `{"vaults":{"v":{"path":"` + vault + `"}}}`
	if err := os.WriteFile(filepath.Join(cfgDir, "obsidian.json"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(vault, "a.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	for label, target := range map[string]string{
		"notion": "https://www.notion.so/x", "linear": "https://linear.app/a/issue/B-1",
		"github": "https://github.com/a/b", "web": "https://example.com",
		"note": filepath.Join(vault, "a.md"), "gone-note": filepath.Join(vault, "gone.md"),
		"plain": filepath.Join(home, "plain"), "gone": filepath.Join(home, "gone"),
	} {
		if _, err := e.s.Apply(store.Change{PlotID: e.plot.ID, Actor: store.Actor{Kind: store.ActorCLI},
			Edits: []store.Edit{{Op: store.OpAddLink, Label: store.S(label), Target: store.S(target)}}}); err != nil {
			t.Fatal(err)
		}
	}
	var out struct {
		Links []struct {
			Label  string `json:"label"`
			Kind   string `json:"kind"`
			Exists *bool  `json:"exists"`
		} `json:"links"`
	}
	if err := json.Unmarshal([]byte(e.ok("get_plot", map[string]any{"plot": e.plot.ID})), &out); err != nil {
		t.Fatal(err)
	}
	type want struct {
		kind   string
		exists string // "", "yes", or "no"
	}
	wants := map[string]want{
		"notion": {"notion", ""}, "linear": {"linear", ""}, "github": {"github", ""}, "web": {"url", ""},
		"note": {"vault", "yes"}, "gone-note": {"vault", "no"}, "plain": {"path", "yes"}, "gone": {"path", "no"},
	}
	if len(out.Links) != len(wants) {
		t.Fatalf("%d links", len(out.Links))
	}
	for _, l := range out.Links {
		w := wants[l.Label]
		got := ""
		if l.Exists != nil {
			got = map[bool]string{true: "yes", false: "no"}[*l.Exists]
		}
		if l.Kind != w.kind || got != w.exists {
			t.Errorf("%s: kind %q exists %q, want %q %q", l.Label, l.Kind, got, w.kind, w.exists)
		}
	}
}
