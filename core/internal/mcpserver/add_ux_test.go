package mcpserver_test

import (
	"path/filepath"
	"testing"
)

// Ticket 78: add_link with no label takes the label from the target.
func TestAddLinkWithNoLabel(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	e.ok("add_link", map[string]any{"target": "https://github.com/me/app/pull/9"})
	if l := e.plotNow(e.plot.ID).Links; len(l) != 1 || l[0].Label != "app#9" {
		t.Fatalf("links %+v", l)
	}
}

// Ticket 78: add_repo and create_plot refuse a repo path that does not exist.
func TestRepoPathMustBeAFolder(t *testing.T) {
	gone := filepath.Join(t.TempDir(), "gone")
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	e.fail("add_repo", map[string]any{"path": gone})
	e.fail("create_plot", map[string]any{"name": "N", "what": "w", "why": "y",
		"repos": []map[string]any{{"path": gone}}})
	if r := e.plotNow(e.plot.ID).Repos; len(r) != 0 {
		t.Fatalf("repos %+v", r)
	}
}
