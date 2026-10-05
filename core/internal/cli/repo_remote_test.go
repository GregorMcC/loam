package cli

import (
	"encoding/json"
	"os"
	"os/exec"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// lrGitRepo makes a git repo in dir with an origin remote. Git runs with no global config.
func lrGitRepo(t *testing.T, dir, origin string) {
	t.Helper()
	for _, args := range [][]string{{"init", "-q"}, {"remote", "add", "origin", origin}} {
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
}

// Ticket 77: a repo add brings the repo's remote as a link, in the same change.
func TestRepoAddAddsTheRemoteAsALink(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	d := lrRepoDirs(t, 2)
	lrGitRepo(t, d[0], "git@github.com:me/app.git")
	out, _, err := lrRun(t, "", "repo", "add", "alpha", d[0], "--json")
	if err != nil {
		t.Fatal(err)
	}
	got := lrPlot(t, s, p.ID)
	if len(got.Repos) != 1 || len(got.Links) != 1 || got.Links[0].Label != "app on GitHub" ||
		got.Links[0].Target != "https://github.com/me/app" {
		t.Fatalf("repos %+v links %+v", got.Repos, got.Links)
	}
	var res struct {
		ChangeID int64 `json:"change_id"`
		Repo     struct {
			Path string `json:"path"`
		} `json:"repo"`
	}
	if err := json.Unmarshal([]byte(out), &res); err != nil || res.Repo.Path != d[0] {
		t.Fatalf("output %s: %v", out, err)
	}

	// One undo removes the repo and its link.
	if _, _, err := lrRun(t, "", "undo", lrItoa(res.ChangeID)); err != nil {
		t.Fatal(err)
	}
	if got := lrPlot(t, s, p.ID); len(got.Repos) != 0 || len(got.Links) != 0 {
		t.Fatalf("after undo: repos %+v links %+v", got.Repos, got.Links)
	}

	// A folder with no remote adds no link.
	if _, _, err := lrRun(t, "", "repo", "add", "alpha", d[1]); err != nil {
		t.Fatal(err)
	}
	if got := lrPlot(t, s, p.ID); len(got.Repos) != 1 || len(got.Links) != 0 {
		t.Fatalf("repos %+v links %+v", got.Repos, got.Links)
	}
}

// A path that starts with ~ is in your home folder. The app runs loam in /, so filepath.Abs alone
// made "/~/proj".
func TestRepoAddExpandsTheHomeFolder(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	home := lrRepoDirs(t, 1)[0]
	t.Setenv("HOME", home)
	if err := os.Mkdir(home+"/proj", 0o755); err != nil {
		t.Fatal(err)
	}
	t.Chdir("/")
	if _, _, err := lrRun(t, "", "repo", "add", "alpha", "~/proj"); err != nil {
		t.Fatal(err)
	}
	if r := lrPlot(t, s, p.ID).Repos; len(r) != 1 || r[0].Path != home+"/proj" {
		t.Fatalf("repos %+v", r)
	}
}
