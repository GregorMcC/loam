package run

import (
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// TAS-176: a fix goes in the repo of the run that it fixes: the repo of its
// draft, else the repo of its worktree, else its folder. A repo that is no
// longer in the plot gives no repo, so the run takes its default.
func TestAFixTakesTheRepoOfTheRunThatItFixes(t *testing.T) {
	s, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	res, err := s.CreatePlot(store.PlotInput{Name: "Runs"}, store.Actor{Kind: store.ActorCLI})
	if err != nil {
		t.Fatal(err)
	}
	plot := store.Plot{ID: res.Plot.ID, Repos: []store.Repo{{ID: "repoaaaaaa", Path: "/src/app"}, {ID: "repobbbbbb", Path: "/src/api"}}}
	wt, err := s.AddWorktree(store.Worktree{PlotID: plot.ID, Repo: "/src/api", Name: "fix", Branch: "fix", Path: "/wt/fix"})
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name string
		run  store.Run
		want string
	}{
		{"draft", store.Run{Shape: &store.RunShape{Repo: "repobbbbbb"}, Folder: "/src/app"}, "/src/api"},
		{"worktree", store.Run{WorktreeID: wt.ID, Folder: "/wt/fix"}, "/src/api"},
		{"folder", store.Run{Folder: "/src/app"}, "/src/app"},
		{"gone worktree", store.Run{WorktreeID: "gone", Folder: "/wt/gone"}, ""},
		{"removed repo", store.Run{Shape: &store.RunShape{Repo: "repocccccc"}}, ""},
	} {
		if got := fixedRepo(s, plot, c.run); got != c.want {
			t.Errorf("%s: repo %q, want %q", c.name, got, c.want)
		}
	}
}
