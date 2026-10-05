package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// openEnv makes a plot with links of every kind, a fake open command, and a
// fake home with an Obsidian config that lists two nested vaults.
type openEnv struct {
	s     *store.Store
	plot  store.Plot
	log   string
	root  string
	outer string
	inner string
}

func newOpenEnv(t *testing.T) *openEnv {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(root, "home")
	t.Setenv("HOME", home)
	e := &openEnv{root: root, outer: filepath.Join(root, "Notes"), inner: filepath.Join(root, "Notes", "Inner")}
	for _, d := range []string{filepath.Join(e.inner, "sub"), filepath.Join(root, "plain"), filepath.Join(home, "Library", "Application Support", "obsidian")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{filepath.Join(e.outer, "outer.md"), filepath.Join(e.inner, "sub", "inner.md"), filepath.Join(root, "plain", "a.txt")} {
		if err := os.WriteFile(f, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cfg, _ := json.Marshal(map[string]any{"vaults": map[string]any{
		"a": map[string]any{"path": e.outer}, "b": map[string]any{"path": e.inner}}})
	if err := os.WriteFile(filepath.Join(home, "Library", "Application Support", "obsidian", "obsidian.json"), cfg, 0o644); err != nil {
		t.Fatal(err)
	}
	e.log = filepath.Join(root, "open.log")
	script := "#!/bin/sh\necho \"$*\" >> \"" + e.log + "\"\n"
	bin := filepath.Join(root, "open")
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LOAM_OPEN", bin)
	s, p := linkRepoEnv(t, store.PlotInput{Links: []store.LinkInput{
		{Label: "Notion", Target: "https://www.notion.so/Loam-1"},
		{Label: "Linear", Target: "https://linear.app/a/issue/B-1"},
		{Label: "GitHub", Target: "https://github.com/a/b"},
		{Label: "Web", Target: "https://example.com"},
		{Label: "Plain file", Target: filepath.Join(root, "plain", "a.txt")},
		{Label: "Plain folder", Target: filepath.Join(root, "plain")},
		{Label: "Outer note", Target: filepath.Join(e.outer, "outer.md")},
		{Label: "Inner note", Target: filepath.Join(e.inner, "sub", "inner.md")},
		{Label: "Vault folder", Target: e.inner},
		{Label: "Gone", Target: filepath.Join(root, "plain", "gone.txt")},
		{Label: "Gone in vault", Target: filepath.Join(e.inner, "gone.md")},
		{Label: "Dup", Target: "https://example.com/1"},
		{Label: "Dup", Target: "https://example.com/2"},
	}})
	e.s, e.plot = s, p
	return e
}

func (e *openEnv) opened(t *testing.T) []string {
	t.Helper()
	b, err := os.ReadFile(e.log)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(b)), "\n")
}

func TestOpenEachKind(t *testing.T) {
	e := newOpenEnv(t)
	uri := func(p string) string {
		return "obsidian://open?path=" + strings.NewReplacer("/", "%2F", " ", "%20").Replace(p)
	}
	for _, c := range []struct{ label, want string }{
		{"Notion", "https://www.notion.so/Loam-1"},
		{"Linear", "https://linear.app/a/issue/B-1"},
		{"GitHub", "https://github.com/a/b"},
		{"Web", "https://example.com"},
		{"Plain file", filepath.Join(e.root, "plain", "a.txt")},
		{"Plain folder", filepath.Join(e.root, "plain")},
		{"Outer note", uri(filepath.Join(e.outer, "outer.md"))},
		{"Inner note", uri(filepath.Join(e.inner, "sub", "inner.md"))},
		{"Vault folder", e.inner},
	} {
		if _, _, err := lrRun(t, "", "open", "alpha", c.label); err != nil {
			t.Fatalf("%s: %v", c.label, err)
		}
		got := e.opened(t)
		if len(got) == 0 || got[len(got)-1] != c.want {
			t.Errorf("%s: open ran with %q, want %q", c.label, got, c.want)
		}
	}
}

func TestOpenByLinkID(t *testing.T) {
	e := newOpenEnv(t)
	id := e.plot.Links[3].ID
	out, _, err := lrRun(t, "", "open", e.plot.ID, id, "--json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Plot, LinkID, Kind, OpenedWith string
	}
	var raw map[string]string
	if err := json.Unmarshal([]byte(out), &raw); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	v.Plot, v.LinkID, v.Kind, v.OpenedWith = raw["plot"], raw["link_id"], raw["kind"], raw["opened_with"]
	if v.Plot != e.plot.ID || v.LinkID != id || v.Kind != "url" || v.OpenedWith != "browser" || len(raw) != 4 {
		t.Fatalf("%v", raw)
	}
	if got := e.opened(t); len(got) != 1 || got[0] != "https://example.com" {
		t.Fatalf("open ran with %q", got)
	}
}

func TestOpenMissingPathExits12(t *testing.T) {
	e := newOpenEnv(t)
	for _, label := range []string{"Gone", "Gone in vault"} {
		var o, er bytes.Buffer
		root := NewRootCmd()
		code := execute(root, []string{"open", "alpha", label, "--json"}, &o, &er)
		if code != 12 {
			t.Fatalf("%s: exit %d: %s", label, code, o.String())
		}
		var v struct {
			Error struct {
				Kind    string
				Details struct {
					PlotID string `json:"plot_id"`
					LinkID string `json:"link_id"`
					Path   string `json:"path"`
				}
			}
		}
		if err := json.Unmarshal(o.Bytes(), &v); err != nil {
			t.Fatal(err)
		}
		if v.Error.Kind != "link_path_missing" || v.Error.Details.PlotID != e.plot.ID || v.Error.Details.LinkID == "" || !strings.HasSuffix(v.Error.Details.Path, "gone.txt") && !strings.HasSuffix(v.Error.Details.Path, "gone.md") {
			t.Errorf("%s: %s", label, o.String())
		}
		if er.Len() != 0 {
			t.Errorf("stderr: %q", er.String())
		}
	}
	if got := e.opened(t); got != nil {
		t.Errorf("open ran: %q", got)
	}
}

func TestOpenErrors(t *testing.T) {
	e := newOpenEnv(t)
	run := func(args ...string) int {
		var o, er bytes.Buffer
		return execute(NewRootCmd(), args, &o, &er)
	}
	if got := run("open", "alpha", "Dup"); got != ExitAmbiguous {
		t.Errorf("duplicate label: exit %d", got)
	}
	if got := run("open", "alpha", "Nothing"); got != ExitError {
		t.Errorf("unknown link: exit %d", got)
	}
	if got := run("open", "nosuchplot", "Web"); got != ExitUnknownPlot {
		t.Errorf("unknown plot: exit %d", got)
	}
	if got := run("open", "alpha"); got != ExitInvalid {
		t.Errorf("one argument: exit %d", got)
	}
	if got := e.opened(t); got != nil {
		t.Errorf("open ran: %q", got)
	}
}

func TestOpenTargetWithoutSchemeIsInvalid(t *testing.T) {
	testHome := t.TempDir()
	t.Setenv("HOME", testHome)
	_, p := linkRepoEnv(t, store.PlotInput{Links: []store.LinkInput{{Label: "Odd", Target: "notes.md"}}})
	t.Setenv("LOAM_OPEN", "/nonexistent/open")
	var o, er bytes.Buffer
	if got := execute(NewRootCmd(), []string{"open", p.ID, "Odd"}, &o, &er); got != ExitInvalid {
		t.Fatalf("exit %d: %s", got, er.String())
	}
}

func TestShowJSONHasKindAndExists(t *testing.T) {
	e := newOpenEnv(t)
	out, _, err := lrRun(t, "", "show", "alpha", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Links []struct {
			Label  string `json:"label"`
			Kind   string `json:"kind"`
			Exists *bool  `json:"exists"`
		} `json:"links"`
	}
	if err := json.Unmarshal([]byte(out), &v); err != nil {
		t.Fatal(err)
	}
	yes, no := true, false
	want := map[string]struct {
		kind   string
		exists *bool
	}{
		"Notion": {"notion", nil}, "Linear": {"linear", nil}, "GitHub": {"github", nil}, "Web": {"url", nil},
		"Plain file": {"path", &yes}, "Plain folder": {"path", &yes},
		"Outer note": {"vault", &yes}, "Inner note": {"vault", &yes}, "Vault folder": {"vault", &yes},
		"Gone": {"path", &no}, "Gone in vault": {"vault", &no},
	}
	seen := 0
	for _, l := range v.Links {
		w, ok := want[l.Label]
		if !ok {
			continue
		}
		seen++
		if l.Kind != w.kind || (w.exists == nil) != (l.Exists == nil) || (w.exists != nil && *w.exists != *l.Exists) {
			t.Errorf("%s: kind %q exists %v, want %q %v", l.Label, l.Kind, l.Exists, w.kind, w.exists)
		}
	}
	if seen != len(want) {
		t.Errorf("saw %d of %d links", seen, len(want))
	}
	_ = e
}

func TestPlotOutputsCarryKind(t *testing.T) {
	newOpenEnv(t)
	for _, args := range [][]string{
		{"set", "alpha", "what", "x", "--json"},
		{"export"},
	} {
		out, _, err := lrRun(t, "", args...)
		if err != nil {
			t.Fatal(err)
		}
		if n := strings.Count(out, `"kind"`); n != 13 {
			t.Errorf("%v: %d kinds, want 13", args, n)
		}
	}
}
