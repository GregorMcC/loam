package linkkind

import (
	"os"
	"path/filepath"
	"testing"
)

// Ticket 78: a link added with no label takes one from its target.
func TestLabel(t *testing.T) {
	dir := t.TempDir()
	app := filepath.Join(dir, "Loam.app")
	if err := os.Mkdir(app, 0o755); err != nil {
		t.Fatal(err)
	}
	home, _ := os.UserHomeDir()
	for _, c := range []struct{ target, want string }{
		{"/Users/me/notes/Design spec 2026-01-15.md", "Design spec 2026-01-15"},
		{"/Users/me/repo/docs/contract.md", "contract"},
		{"/Users/me/repo/Makefile", "Makefile"},
		{"/Users/me/repo/.env", ".env"},
		{"  /Users/me/repo/BUILD.md  ", "BUILD"},
		{app, "Loam.app"},
		{app + "/", "Loam.app"},
		{"~/notes/plan.md", "plan"},
		{"~", filepath.Base(home)},
		{"/", "/"},
		{"https://github.com/GregorMcC/loam", "loam on GitHub"},
		{"https://github.com/GregorMcC/loam/", "loam on GitHub"},
		{"https://github.com/GregorMcC/loam/issues/12", "loam#12"},
		{"https://github.com/GregorMcC/loam/pull/7/files", "loam#7"},
		{"https://github.com/GregorMcC/loam/blob/main/docs/contract.md", "contract"},
		{"https://github.com/GregorMcC/loam/tree/main/core", "core"},
		{"https://github.com/GregorMcC", "GregorMcC on GitHub"},
		{"https://github.com", "GitHub"},
		{"https://linear.app/acme/issue/ENG-12/fix-the-thing", "ENG-12"},
		{"https://linear.app/acme/project/loam-redesign-4f2a9c", "Linear"},
		{"https://www.notion.so/acme/Loam-redesign-brief-0123456789abcdef0123456789abcdef", "Loam redesign brief"},
		{"https://www.notion.so/0123456789abcdef0123456789abcdef", "Notion page"},
		{"https://www.notion.so/Roadmap-0123456789abcdef0123456789abcdef?pvs=4", "Roadmap"},
		{"obsidian://open?vault=Notes&file=Projects%2FLoam%20plan", "Loam plan"},
		{"obsidian://open?vault=Notes&file=Ideas.md", "Ideas"},
		{"obsidian://open?vault=Notes", "Notes"},
		{"https://www.example.com/docs/page?x=1", "example.com"},
		{"http://localhost:8080", "localhost:8080"},
		{"mailto:me@example.com", "mailto:me@example.com"},
		{"", ""},
	} {
		if got := Label(c.target); got != c.want {
			t.Errorf("Label(%q) = %q, want %q", c.target, got, c.want)
		}
	}
}
