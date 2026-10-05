package mcpserver_test

import (
	"testing"

	"github.com/GregorMcC/loam/core/internal/testutil"
)

// Ticket 91: add_repo and create_plot switch the checkout to the default branch of origin.
func TestRepoAddsSwitchToTheDefaultBranch(t *testing.T) {
	testutil.GitEnv(t)
	e := setup(t, opts{plotEnv: "ALPHA"})
	repo, _ := testutil.GitRepo(t)
	testutil.Git(t, repo, "switch", "-c", "feature")
	e.ok("get_plot", nil)
	e.ok("add_repo", map[string]any{"path": repo})
	if b := testutil.Git(t, repo, "branch", "--show-current"); b != "main" {
		t.Fatalf("add_repo: branch %q", b)
	}

	testutil.Git(t, repo, "switch", "feature")
	e.ok("create_plot", map[string]any{"name": "Gamma", "what": "w", "why": "y",
		"repos": []map[string]any{{"path": repo}}})
	if b := testutil.Git(t, repo, "branch", "--show-current"); b != "main" {
		t.Fatalf("create_plot: branch %q", b)
	}
}
