package store_test

import (
	"errors"
	"slices"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func addRepo(t *testing.T, s *store.Store, plotID, path string) store.Repo {
	t.Helper()
	res, err := s.Apply(store.Change{PlotID: plotID, Actor: store.Actor{Kind: store.ActorCLI},
		Edits: []store.Edit{{Op: store.OpAddRepo, Path: store.S(path)}}})
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range res.Plot.Repos {
		if r.Path == path {
			return r
		}
	}
	t.Fatal("repo not added")
	return store.Repo{}
}

func TestRepoSettingsAreKeyedByPathAndShowOnEveryPlot(t *testing.T) {
	s := openStore(t)
	a, b := newPlot(t, s, "A"), newPlot(t, s, "B")
	addRepo(t, s, a.ID, "/work/app")
	addRepo(t, s, b.ID, "/work/app")

	if err := s.SetRepoSettings("/work/app", store.S("make setup"), &[]string{".env", "config/local.json"}); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{a.ID, b.ID} {
		p, err := s.GetPlot(id)
		if err != nil {
			t.Fatal(err)
		}
		r := p.Repos[0]
		if r.Setup != "make setup" || !slices.Equal(r.Copy, []string{".env", "config/local.json"}) {
			t.Fatalf("plot %s repo %+v", id, r)
		}
	}
	// A nil field stays. An empty value clears.
	if err := s.SetRepoSettings("/work/app", nil, &[]string{}); err != nil {
		t.Fatal(err)
	}
	got, err := s.RepoSettings("/work/app")
	if err != nil {
		t.Fatal(err)
	}
	if got.Setup != "make setup" || len(got.Copy) != 0 {
		t.Fatalf("%+v", got)
	}
	// A path with no record has empty settings.
	if got, err := s.RepoSettings("/other"); err != nil || got.Setup != "" || got.Copy != nil {
		t.Fatalf("%+v %v", got, err)
	}
	if err := s.SetRepoSettings("relative", store.S("x"), nil); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("want invalid, got %v", err)
	}
}

func TestRepoSettingsAreNotChanges(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	addRepo(t, s, p.ID, "/work/app")
	before, _ := s.GetPlot(p.ID)
	if err := s.SetRepoSettings("/work/app", store.S("make"), nil); err != nil {
		t.Fatal(err)
	}
	after, _ := s.GetPlot(p.ID)
	if after.Revision != before.Revision {
		t.Fatalf("revision moved from %d to %d", before.Revision, after.Revision)
	}
}

func TestWorktreeRecords(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	other := newPlot(t, s, "B")
	w, err := s.AddWorktree(store.Worktree{PlotID: p.ID, Repo: "/work/app", Name: "fix-x", Branch: "fix-x", Base: "origin/main", Path: "/home/w/app-fix-x"})
	if err != nil {
		t.Fatal(err)
	}
	if len(w.ID) != store.IDLength || w.CreatedAt.IsZero() || w.SetupDone {
		t.Fatalf("%+v", w)
	}
	if _, err := s.AddWorktree(store.Worktree{PlotID: p.ID, Repo: "/work/app", Name: "fix-x", Branch: "fix-x", Path: "/home/w/other"}); !errors.Is(err, store.ErrDuplicate) {
		t.Fatalf("same name: %v", err)
	}
	if _, err := s.AddWorktree(store.Worktree{PlotID: other.ID, Repo: "/work/app", Name: "y", Branch: "y", Path: "/home/w/app-fix-x"}); !errors.Is(err, store.ErrDuplicate) {
		t.Fatalf("same path: %v", err)
	}
	if _, err := s.AddWorktree(store.Worktree{PlotID: "nosuchplot", Repo: "/r", Name: "n", Branch: "n", Path: "/p"}); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("no plot: %v", err)
	}

	got, err := s.GetWorktree(w.ID)
	if err != nil || got.Path != w.Path || got.Base != "origin/main" {
		t.Fatalf("%+v %v", got, err)
	}
	if byPath, err := s.WorktreeByPath("/home/w/app-fix-x"); err != nil || byPath.ID != w.ID {
		t.Fatalf("%+v %v", byPath, err)
	}
	if _, err := s.WorktreeByPath("/nope"); !errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}
	if all, _ := s.ListWorktrees(""); len(all) != 1 {
		t.Fatalf("%v", all)
	}
	if none, _ := s.ListWorktrees(other.ID); len(none) != 0 || none == nil {
		t.Fatalf("%#v", none)
	}

	if err := s.MarkWorktreeSetup(w.ID); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.GetWorktree(w.ID); !got.SetupDone {
		t.Fatal("setup not marked")
	}
	if err := s.RemoveWorktree(w.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.GetWorktree(w.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}
	if err := s.RemoveWorktree(w.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}
}

// TAS-55: a session works in one worktree at a time, and the record of the worktree lists its sessions, so the
// app can show a session under the worktree that it works in.
func TestSessionWorktreeLinks(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	add := func(name string) store.Worktree {
		t.Helper()
		w, err := s.AddWorktree(store.Worktree{PlotID: p.ID, Repo: "/work/app", Name: name, Branch: name, Path: "/home/w/app-" + name})
		if err != nil {
			t.Fatal(err)
		}
		return w
	}
	a, b := add("a"), add("b")
	if a.Sessions == nil || len(a.Sessions) != 0 {
		t.Fatalf("a new worktree has sessions %#v", a.Sessions)
	}
	sessions := func(id string) []string {
		t.Helper()
		w, err := s.GetWorktree(id)
		if err != nil {
			t.Fatal(err)
		}
		return w.Sessions
	}
	for _, link := range [][2]string{{"s1", a.ID}, {"s2", a.ID}} {
		if err := s.SetSessionWorktree(link[0], link[1]); err != nil {
			t.Fatal(err)
		}
	}
	if got := sessions(a.ID); !slices.Equal(got, []string{"s1", "s2"}) {
		t.Fatalf("a: %q", got)
	}
	// The latest wins: s1 moves to b.
	if err := s.SetSessionWorktree("s1", b.ID); err != nil {
		t.Fatal(err)
	}
	if got, gotB := sessions(a.ID), sessions(b.ID); !slices.Equal(got, []string{"s2"}) || !slices.Equal(gotB, []string{"s1"}) {
		t.Fatalf("a %q, b %q", got, gotB)
	}
	if all, _ := s.ListWorktrees(p.ID); len(all) != 2 || !slices.Equal(all[1].Sessions, []string{"s1"}) {
		t.Fatalf("%+v", all)
	}
	if err := s.SetSessionWorktree("s3", "nosuchworktree"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("no worktree: %v", err)
	}
	// An empty ID clears the link.
	if err := s.SetSessionWorktree("s2", ""); err != nil {
		t.Fatal(err)
	}
	if got := sessions(a.ID); len(got) != 0 {
		t.Fatalf("a: %q", got)
	}
	// A worktree with a link can go.
	if err := s.RemoveWorktree(b.ID); err != nil {
		t.Fatal(err)
	}
}

func TestWorktreeRecordsAreNotChanges(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	before, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID})
	w, _ := s.AddWorktree(store.Worktree{PlotID: p.ID, Repo: "/work/app", Name: "n", Branch: "n", Path: "/p"})
	if err := s.MarkWorktreeSetup(w.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.RemoveWorktree(w.ID); err != nil {
		t.Fatal(err)
	}
	after, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID})
	if len(after) != len(before) {
		t.Fatalf("change log grew from %d to %d", len(before), len(after))
	}
}

func TestRemoveRepoRefusedWhilePlotHasWorktrees(t *testing.T) {
	s := openStore(t)
	a, b := newPlot(t, s, "A"), newPlot(t, s, "B")
	ra := addRepo(t, s, a.ID, "/work/app")
	rb := addRepo(t, s, b.ID, "/work/app")
	w, _ := s.AddWorktree(store.Worktree{PlotID: a.ID, Repo: "/work/app", Name: "n", Branch: "n", Path: "/p"})

	rm := func(plot string, r store.Repo) error {
		_, err := s.Apply(store.Change{PlotID: plot, Actor: store.Actor{Kind: store.ActorCLI},
			Edits: []store.Edit{{Op: store.OpRemoveRepo, Item: store.RepoItem(r.ID)}}})
		return err
	}
	if err := rm(a.ID, ra); !errors.Is(err, store.ErrHasWorktrees) {
		t.Fatalf("want ErrHasWorktrees, got %v", err)
	}
	if p, _ := s.GetPlot(a.ID); len(p.Repos) != 1 {
		t.Fatal("repo was removed")
	}
	// Another plot with the same repo has no worktree, so it can remove it.
	if err := rm(b.ID, rb); err != nil {
		t.Fatal(err)
	}
	if err := s.RemoveWorktree(w.ID); err != nil {
		t.Fatal(err)
	}
	if err := rm(a.ID, ra); err != nil {
		t.Fatal(err)
	}
}

// The after merge setting is per repo path, as the other settings are. Ask is
// the default, also for a path with no record.
func TestAfterMergeSetting(t *testing.T) {
	s := openStore(t)
	a, b := newPlot(t, s, "A"), newPlot(t, s, "B")
	addRepo(t, s, a.ID, "/work/app")
	addRepo(t, s, b.ID, "/work/app")
	p, err := s.GetPlot(a.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got := p.Repos[0].AfterMerge; got != store.AfterMergeAsk {
		t.Fatalf("default %q", got)
	}
	if got, err := s.RepoSettings("/other"); err != nil || got.AfterMerge != store.AfterMergeAsk {
		t.Fatalf("%+v %v", got, err)
	}

	before := p.Revision
	if err := s.SetAfterMerge("/work/app", store.AfterMergeRemove); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{a.ID, b.ID} {
		p, err := s.GetPlot(id)
		if err != nil {
			t.Fatal(err)
		}
		if p.Repos[0].AfterMerge != store.AfterMergeRemove {
			t.Fatalf("plot %s repo %+v", id, p.Repos[0])
		}
		if id == a.ID && p.Revision != before {
			t.Fatalf("the setting made a change: revision %d, was %d", p.Revision, before)
		}
	}
	// The other settings stay.
	if err := s.SetRepoSettings("/work/app", store.S("make"), nil); err != nil {
		t.Fatal(err)
	}
	if err := s.SetAfterMerge("/work/app", store.AfterMergeKeep); err != nil {
		t.Fatal(err)
	}
	if got, err := s.RepoSettings("/work/app"); err != nil || got.Setup != "make" || got.AfterMerge != store.AfterMergeKeep {
		t.Fatalf("%+v %v", got, err)
	}

	// A value that is not ask, remove, or keep changes nothing.
	for _, bad := range []store.AfterMerge{"", "never", "Ask"} {
		if err := s.SetAfterMerge("/work/app", bad); !errors.Is(err, store.ErrInvalid) {
			t.Fatalf("%q: want invalid, got %v", bad, err)
		}
	}
	if got, _ := s.RepoSettings("/work/app"); got.AfterMerge != store.AfterMergeKeep {
		t.Fatalf("%+v", got)
	}
	if err := s.SetAfterMerge("relative", store.AfterMergeAsk); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("want invalid, got %v", err)
	}
}

func TestParseAfterMerge(t *testing.T) {
	for _, v := range []string{"ask", "remove", "keep"} {
		if got, err := store.ParseAfterMerge(v); err != nil || string(got) != v {
			t.Fatalf("%q: %q %v", v, got, err)
		}
	}
	if _, err := store.ParseAfterMerge("delete"); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("want invalid, got %v", err)
	}
}
