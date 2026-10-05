package linkkind

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClassifyURLs(t *testing.T) {
	for _, c := range []struct{ target, kind string }{
		{"https://www.notion.so/Loam-0123456789abcdef", Notion},
		{"https://notion.so/x", Notion},
		{"https://acme.notion.site/Page-1", Notion},
		{"https://linear.app/acme/issue/ENG-12/fix", Linear},
		{"https://github.com/GregorMcC/loam/issues/3", GitHub},
		{"https://www.github.com/GregorMcC/loam", GitHub},
		{"https://example.com/spec", URL},
		{"http://localhost:8080", URL},
		{"https://notnotion.so/x", URL},
		{"https://github.com.evil.example/x", URL},
		{"mailto:me@example.com", URL},
		{"  https://github.com/a/b  ", GitHub},
		{"HTTPS://GitHub.com/a/b", GitHub},
	} {
		got := Classify(c.target, nil)
		if got.Kind != c.kind || got.Local || got.Exists {
			t.Errorf("Classify(%q) = %+v, want kind %s and not local", c.target, got, c.kind)
		}
	}
}

func TestClassifyLocalPaths(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "a.txt")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		target string
		exists bool
	}{{dir, true}, {file, true}, {filepath.Join(dir, "nope"), false}} {
		got := Classify(c.target, nil)
		if got.Kind != Path || !got.Local || got.Exists != c.exists || got.Path != c.target {
			t.Errorf("Classify(%q) = %+v", c.target, got)
		}
	}
	if got := Classify(dir+"/sub/../a.txt", nil); got.Path != file || !got.Exists {
		t.Errorf("the path is not cleaned: %+v", got)
	}
}

func TestClassifyHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.Mkdir(filepath.Join(home, "notes"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{"~/notes", "~"} {
		got := Classify(target, nil)
		if !got.Local || !got.Exists || !strings.HasPrefix(got.Path, home) {
			t.Errorf("Classify(%q) = %+v", target, got)
		}
	}
	if got := Classify("~/gone", nil); !got.Local || got.Exists || got.Path != filepath.Join(home, "gone") {
		t.Errorf("Classify(~/gone) = %+v", got)
	}
}

func TestClassifyVaults(t *testing.T) {
	root := t.TempDir()
	outer := filepath.Join(root, "Notes")
	inner := filepath.Join(outer, "Work", "Inner")
	if err := os.MkdirAll(filepath.Join(inner, "deep"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outer, "a.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(inner, "deep", "b.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	// A sibling folder that shares a name prefix with a vault is not in it.
	sibling := outer + "-old"
	if err := os.MkdirAll(sibling, 0o755); err != nil {
		t.Fatal(err)
	}
	vaults := []string{outer, inner}
	for _, c := range []struct {
		target, kind, vault string
	}{
		{filepath.Join(outer, "a.md"), Vault, outer},
		{outer, Vault, outer},
		{filepath.Join(inner, "deep", "b.md"), Vault, inner}, // the most specific vault wins
		{filepath.Join(inner, "deep"), Vault, inner},
		{filepath.Join(outer, "missing.md"), Vault, outer}, // a missing path still has a kind
		{sibling, Path, ""},
		{root, Path, ""},
	} {
		got := Classify(c.target, vaults)
		if got.Kind != c.kind || got.Vault != c.vault {
			t.Errorf("Classify(%q) = %+v, want kind %s vault %q", c.target, got, c.kind, c.vault)
		}
	}
	// The order of the vault list does not matter.
	if got := Classify(filepath.Join(inner, "deep", "b.md"), []string{inner, outer}); got.Vault != inner {
		t.Errorf("vault %q, want %q", got.Vault, inner)
	}
}

func writeConfig(t *testing.T, home, body string) {
	t.Helper()
	dir := filepath.Join(home, "Library", "Application Support", "obsidian")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "obsidian.json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestVaultsReadsObsidianConfig(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if got := Vaults(); len(got) != 0 {
		t.Errorf("no config: got %v", got)
	}
	writeConfig(t, home, `{"vaults":{"a1":{"path":"/v/one/","ts":1,"open":true},"b2":{"path":"/v/two"},"c3":{"ts":5},"d4":{"path":""}},"updateDisabled":true}`)
	got := Vaults()
	want := map[string]bool{"/v/one": true, "/v/two": true}
	if len(got) != 2 || !want[got[0]] || !want[got[1]] {
		t.Errorf("Vaults() = %v", got)
	}
	writeConfig(t, home, `not json`)
	if got := Vaults(); len(got) != 0 {
		t.Errorf("bad config: got %v", got)
	}
}
