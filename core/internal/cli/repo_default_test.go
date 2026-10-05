package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// Ticket 91: a repo add switches the checkout to the default branch of origin.
// A dirty checkout keeps its branch, and the warning is in the JSON and on stderr.
func TestRepoAddSwitchesToTheDefaultBranch(t *testing.T) {
	linkRepoEnv(t, store.PlotInput{})
	testutil.GitEnv(t)
	repo, _ := testutil.GitRepo(t)
	testutil.Git(t, repo, "switch", "-c", "feature")
	out, errOut, err := lrRun(t, "", "repo", "add", "alpha", repo, "--json")
	if err != nil {
		t.Fatal(err)
	}
	if b := testutil.Git(t, repo, "branch", "--show-current"); b != "main" || errOut != "" || strings.Contains(out, "warnings") {
		t.Fatalf("branch %q, stderr %q, output %s", b, errOut, out)
	}

	repo2, _ := testutil.GitRepoAt(t, filepath.Join(t.TempDir(), "r.git"), filepath.Join(t.TempDir(), "web"))
	testutil.Git(t, repo2, "switch", "-c", "feature")
	if err := os.WriteFile(filepath.Join(repo2, "README.md"), []byte("changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out, errOut, err = lrRun(t, "", "repo", "add", "alpha", repo2, "--json")
	if err != nil {
		t.Fatal(err)
	}
	var res struct {
		Warnings []string `json:"warnings"`
	}
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		t.Fatalf("output %s: %v", out, err)
	}
	if len(res.Warnings) != 1 || !strings.Contains(res.Warnings[0], "uncommitted changes") ||
		!strings.Contains(errOut, "uncommitted changes") {
		t.Fatalf("warnings %v, stderr %q", res.Warnings, errOut)
	}
	if b := testutil.Git(t, repo2, "branch", "--show-current"); b != "feature" {
		t.Fatalf("branch %q", b)
	}
}
