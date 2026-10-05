package store_test

import (
	"errors"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func TestArchiveKeepsPlaceAndWritesNoChange(t *testing.T) {
	s := openStore(t)
	a, b, c := newPlot(t, s, "A"), newPlot(t, s, "B"), newPlot(t, s, "C")
	before, _ := s.ListChanges(store.ChangeQuery{})

	if err := s.SetArchived(b.ID, true); err != nil {
		t.Fatal(err)
	}
	if err := s.SetArchived(b.ID, true); err != nil { // again: no error
		t.Fatal(err)
	}
	all, _ := s.ListPlots()
	if len(all) != 3 || !all[1].Archived || all[0].Archived || all[2].Archived || all[1].ID != b.ID {
		t.Fatalf("%+v", all)
	}
	if got := store.FilterPlots(all, false); len(got) != 2 || got[0].ID != a.ID || got[1].ID != c.ID {
		t.Fatalf("active %+v", got)
	}
	if got := store.FilterPlots(all, true); len(got) != 1 || got[0].ID != b.ID {
		t.Fatalf("archived %+v", got)
	}
	if p, _ := s.GetPlot(b.ID); !p.Archived {
		t.Fatal("GetPlot does not show the flag")
	}
	if err := s.SetArchived(b.ID, false); err != nil {
		t.Fatal(err)
	}
	all, _ = s.ListPlots()
	if all[1].ID != b.ID || all[1].Archived {
		t.Fatalf("unarchive lost the place: %+v", all)
	}
	if after, _ := s.ListChanges(store.ChangeQuery{}); len(after) != len(before) {
		t.Fatalf("archive wrote %d change(s)", len(after)-len(before))
	}
	if err := s.SetArchived("nosuchplot", true); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("%v", err)
	}
}

func TestDeletePlotRefusals(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	if _, err := s.DeletePlot(p.ID); !errors.Is(err, store.ErrNotArchived) {
		t.Fatalf("active plot: %v", err)
	}
	if _, err := s.DeletePlot("nosuchplot"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("unknown plot: %v", err)
	}
	if _, err := s.AddWorktree(store.Worktree{PlotID: p.ID, Repo: "/r", Name: "x", Branch: "x", Path: "/w/x"}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetArchived(p.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DeletePlot(p.ID); !errors.Is(err, store.ErrHasWorktrees) {
		t.Fatalf("plot with a worktree: %v", err)
	}
	if _, err := s.GetPlot(p.ID); err != nil {
		t.Fatalf("a refused delete removed the plot: %v", err)
	}
}

func TestDeletePlotRemovesItsRecordsOnly(t *testing.T) {
	s := openStore(t)
	mk := func(name, repo string) store.Plot {
		res, err := s.CreatePlot(store.PlotInput{Name: name,
			Links: []store.LinkInput{{Label: "L", Target: "https://example.com"}},
			Repos: []store.RepoInput{{Path: repo}}}, store.Actor{Kind: store.ActorCLI})
		if err != nil {
			t.Fatal(err)
		}
		return res.Plot
	}
	gone, keep := mk("Gone", "/r/own"), mk("Keep", "/r/shared")
	if _, err := s.Apply(store.Change{PlotID: gone.ID, Actor: store.Actor{Kind: store.ActorCLI},
		Edits: []store.Edit{{Op: store.OpAddRepo, Path: store.S("/r/shared")}}}); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/r/own", "/r/shared"} {
		if err := s.SetRepoSettings(path, store.S("make"), nil); err != nil {
			t.Fatal(err)
		}
	}
	for i, p := range []store.Plot{gone, keep} {
		id := []string{"11111111-2222-4333-8444-555555555555", "22222222-2222-4333-8444-555555555555"}[i]
		if err := s.AddSession(store.SessionRecord{SessionID: id, PlotID: p.ID, StartFolder: "/r/f" + p.Name}); err != nil {
			t.Fatal(err)
		}
		if err := s.SetPIDSession(100+i, id); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.SetArchived(gone.ID, true); err != nil {
		t.Fatal(err)
	}

	recs, err := s.DeletePlot(gone.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(recs) != 1 || recs[0].StartFolder != "/r/fGone" {
		t.Fatalf("%+v", recs)
	}
	if _, err := s.GetPlot(gone.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("plot is still there: %v", err)
	}
	if all, _ := s.ListPlots(); len(all) != 1 || all[0].ID != keep.ID {
		t.Fatalf("%+v", all)
	}
	if cs, _ := s.ListChanges(store.ChangeQuery{PlotID: gone.ID}); len(cs) != 0 {
		t.Fatalf("change log is still there: %v", cs)
	}
	if cs, _ := s.ListChanges(store.ChangeQuery{PlotID: keep.ID}); len(cs) == 0 {
		t.Fatal("the other change log is gone")
	}
	if rs, _ := s.ListSessions(""); len(rs) != 1 || rs[0].PlotID != keep.ID {
		t.Fatalf("%+v", rs)
	}
	if _, found, _ := s.SessionForPID(100); found {
		t.Fatal("the pid record is still there")
	}
	if _, found, _ := s.SessionForPID(101); !found {
		t.Fatal("the other pid record is gone")
	}
	// The settings of a path that another plot holds stay. The others go.
	if rs, _ := s.RepoSettings("/r/own"); rs.Setup != "" {
		t.Fatalf("own settings stay: %+v", rs)
	}
	if rs, _ := s.RepoSettings("/r/shared"); rs.Setup != "make" {
		t.Fatalf("shared settings are gone: %+v", rs)
	}
	if p, err := s.GetPlot(keep.ID); err != nil || len(p.Links) != 1 || len(p.Repos) != 1 {
		t.Fatalf("%+v %v", p, err)
	}
}
