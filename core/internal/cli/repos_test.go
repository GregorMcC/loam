package cli

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func lrRepoDirs(t *testing.T, n int) []string {
	t.Helper()
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for i := 0; i < n; i++ {
		d := filepath.Join(base, string(rune('a'+i)))
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
		out = append(out, d)
	}
	return out
}

func lrAsTerminal(t *testing.T) {
	old := stdinIsTerminal
	stdinIsTerminal = func(any) bool { return true }
	t.Cleanup(func() { stdinIsTerminal = old })
}

func lrThreeRepos(t *testing.T) (*store.Store, store.Plot, []string) {
	d := lrRepoDirs(t, 3)
	s, p := linkRepoEnv(t, store.PlotInput{Repos: []store.RepoInput{{Path: d[0]}, {Path: d[1]}, {Path: d[2]}}})
	return s, p, d
}

func TestRepoAddEditRm(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	d := lrRepoDirs(t, 2)
	if _, _, err := lrRun(t, "", "repo", "add", "alpha", d[0], "--note", "core"); err != nil {
		t.Fatal(err)
	}
	r := lrPlot(t, s, p.ID).Repos
	if len(r) != 1 || r[0].Path != d[0] || !r[0].Main || r[0].Note != "core" {
		t.Fatalf("repos %+v", r)
	}
	t.Chdir(d[1])
	if _, _, err := lrRun(t, "", "repo", "add", "alpha", "."); err != nil {
		t.Fatal(err)
	}
	r = lrPlot(t, s, p.ID).Repos
	if len(r) != 2 || r[1].Main || !filepath.IsAbs(r[1].Path) {
		t.Fatalf("repos %+v", r)
	}
	if _, _, err := lrRun(t, "", "repo", "edit", "alpha", d[0], "--note", "new"); err != nil {
		t.Fatal(err)
	}
	if lrPlot(t, s, p.ID).Repos[0].Note != "new" {
		t.Fatal("note not set")
	}
	if _, _, err := lrRun(t, "", "repo", "edit", "alpha", d[0]); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("err %v", err)
	}
	if _, _, err := lrRun(t, "", "repo", "rm", "alpha", r[1].ID); err != nil {
		t.Fatal(err)
	}
	if n := len(lrPlot(t, s, p.ID).Repos); n != 1 {
		t.Fatalf("%d repos", n)
	}
	if _, _, err := lrRun(t, "", "repo", "rm", "alpha", d[0]); err != nil {
		t.Fatal(err)
	}
	if n := len(lrPlot(t, s, p.ID).Repos); n != 0 {
		t.Fatalf("%d repos", n)
	}
}

func TestRepoMain(t *testing.T) {
	d := lrRepoDirs(t, 2)
	s, p := linkRepoEnv(t, store.PlotInput{Repos: []store.RepoInput{{Path: d[0]}, {Path: d[1]}}})
	if _, _, err := lrRun(t, "", "repo", "main", "alpha", d[1]); err != nil {
		t.Fatal(err)
	}
	if m := lrPlot(t, s, p.ID).MainRepo(); m == nil || m.Path != d[1] {
		t.Fatalf("main %+v", m)
	}
}

func TestRepoRmMainPromotesLastRepo(t *testing.T) {
	d := lrRepoDirs(t, 2)
	s, p := linkRepoEnv(t, store.PlotInput{Repos: []store.RepoInput{{Path: d[0]}, {Path: d[1]}}})
	if _, _, err := lrRun(t, "", "repo", "rm", "alpha", d[1]); err != nil {
		t.Fatal(err)
	}
	if _, _, err := lrRun(t, "", "repo", "rm", "alpha", d[0]); err != nil {
		t.Fatal(err)
	}
	if n := len(lrPlot(t, s, p.ID).Repos); n != 0 {
		t.Fatal("repo left")
	}
}

func TestRepoRmMainOfTwoNeedsNoPrompt(t *testing.T) {
	d := lrRepoDirs(t, 2)
	s, p := linkRepoEnv(t, store.PlotInput{Repos: []store.RepoInput{{Path: d[0]}, {Path: d[1]}}})
	if _, _, err := lrRun(t, "", "repo", "rm", "alpha", d[0]); err != nil {
		t.Fatal(err)
	}
	got := lrPlot(t, s, p.ID)
	if len(got.Repos) != 1 || !got.Repos[0].Main {
		t.Fatalf("%+v", got.Repos)
	}
}

func TestRepoRmMainPrompts(t *testing.T) {
	s, p, d := lrThreeRepos(t)
	lrAsTerminal(t)
	out, _, err := lrRun(t, "2\n", "repo", "rm", "alpha", d[0])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, d[1]) || !strings.Contains(out, d[2]) {
		t.Errorf("prompt does not list the repos:\n%s", out)
	}
	got := lrPlot(t, s, p.ID)
	if len(got.Repos) != 2 || got.MainRepo() == nil || got.MainRepo().Path != d[2] {
		t.Fatalf("%+v", got.Repos)
	}
}

func TestRepoRmMainBadChoiceChangesNothing(t *testing.T) {
	s, p, d := lrThreeRepos(t)
	lrAsTerminal(t)
	if _, _, err := lrRun(t, "9\n", "repo", "rm", "alpha", d[0]); err == nil {
		t.Fatal("want an error")
	}
	if n := len(lrPlot(t, s, p.ID).Repos); n != 3 {
		t.Fatalf("%d repos", n)
	}
}

func TestRepoRmMainWithoutTerminalFails(t *testing.T) {
	s, p, d := lrThreeRepos(t)
	_, _, err := lrRun(t, "1\n", "repo", "rm", "alpha", d[0])
	if !errors.Is(err, store.ErrInvalid) || !strings.Contains(err.Error(), "--main") {
		t.Fatalf("want an invalid error that names --main, got %v", err)
	}
	lrAsTerminal(t)
	if _, _, err := lrRun(t, "1\n", "--json", "repo", "rm", "alpha", d[0]); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("want an invalid error, got %v", err)
	}
	if n := len(lrPlot(t, s, p.ID).Repos); n != 3 {
		t.Fatalf("%d repos", n)
	}
}

func TestRepoRmMainWithFlag(t *testing.T) {
	s, p, d := lrThreeRepos(t)
	if _, _, err := lrRun(t, "", "repo", "rm", "alpha", d[0], "--main", d[1]); err != nil {
		t.Fatal(err)
	}
	got := lrPlot(t, s, p.ID)
	if len(got.Repos) != 2 || got.MainRepo().Path != d[1] {
		t.Fatalf("%+v", got.Repos)
	}
}

func TestRepoStaleExpectAndJSON(t *testing.T) {
	d := lrRepoDirs(t, 1)
	s, p := linkRepoEnv(t, store.PlotInput{Repos: []store.RepoInput{{Path: d[0]}}})
	r := p.Repos[0]
	item := "repo:" + r.ID
	if _, _, err := lrRun(t, "", "repo", "edit", "alpha", r.ID, "--note", "x"); err != nil {
		t.Fatal(err)
	}
	_, _, err := lrRun(t, "", "repo", "edit", "alpha", r.ID, "--note", "y", "--expect", item+"=1")
	var stale *store.StaleError
	if !errors.As(err, &stale) {
		t.Fatalf("err %v", err)
	}
	if lrPlot(t, s, p.ID).Repos[0].Note != "x" {
		t.Fatal("stale write went through")
	}
	out, _, err := lrRun(t, "", "--json", "repo", "edit", "alpha", r.ID, "--note", "z")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		ChangeID int64       `json:"change_id"`
		Repo     *store.Repo `json:"repo"`
	}
	if err := json.Unmarshal([]byte(out), &v); err != nil || v.Repo == nil || v.Repo.Note != "z" {
		t.Fatalf("%v: %s", err, out)
	}
}
