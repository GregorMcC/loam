package cli

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func edit(t *testing.T, s *store.Store, plot, item, val string) int64 {
	t.Helper()
	r, err := s.Apply(store.Change{PlotID: plot, Actor: store.Actor{Kind: store.ActorSession, SessionID: "abcdef123"},
		Edits: []store.Edit{{Op: store.OpSet, Item: item, Value: val}}})
	if err != nil {
		t.Fatal(err)
	}
	return r.ChangeID
}

func TestUndoCommand(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{What: "w0"})
	id := edit(t, s, p.ID, store.ItemWhat, "w1")
	out, _, err := lrRun(t, "", "undo", lrItoa(id), "--json", "--actor", "app")
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		ChangeID int64  `json:"change_id"`
		Undone   int64  `json:"undone"`
		Plot     string `json:"plot"`
	}
	if json.Unmarshal([]byte(out), &got) != nil || got.Undone != id || got.ChangeID <= id || got.Plot != p.ID {
		t.Fatalf("%s", out)
	}
	if lrPlot(t, s, p.ID).What != "w0" {
		t.Fatal("not undone")
	}
	chs, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID, SinceID: id})
	if chs[0].Actor.Kind != store.ActorApp {
		t.Fatalf("actor %+v", chs[0].Actor)
	}
	if _, _, err := lrRun(t, "", "undo", "x"); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("err %v", err)
	}
	if _, _, err := lrRun(t, "", "undo", "9999"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("err %v", err)
	}
}

func TestUndoClashNoTerminal(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	c1 := edit(t, s, p.ID, store.ItemWhere, "one")
	c2 := edit(t, s, p.ID, store.ItemWhere, "two")
	_, _, err := lrRun(t, "", "undo", lrItoa(c1))
	if !errors.Is(err, ErrUndoClash) {
		t.Fatalf("err %v", err)
	}
	b := classify(err)
	if b.ExitCode != ExitUndoClash {
		t.Fatalf("%+v", b)
	}
	raw, _ := json.Marshal(b.Details)
	if !strings.Contains(string(raw), `"later_changes"`) || !strings.Contains(string(raw), `"id":`+lrItoa(c2)) {
		t.Fatalf("details %s", raw)
	}
	if lrPlot(t, s, p.ID).Where != "two" {
		t.Fatal("wrote on clash")
	}
	if _, _, err := lrRun(t, "", "undo", lrItoa(c1), "--overwrite"); err != nil {
		t.Fatal(err)
	}
	if lrPlot(t, s, p.ID).Where != "" {
		t.Fatal("overwrite did not write")
	}
}

func TestUndoClashAsksOnTerminal(t *testing.T) {
	old := stdinIsTerminal
	stdinIsTerminal = func(any) bool { return true }
	t.Cleanup(func() { stdinIsTerminal = old })
	s, p := linkRepoEnv(t, store.PlotInput{})
	c1 := edit(t, s, p.ID, store.ItemWhere, "one")
	edit(t, s, p.ID, store.ItemWhere, "two")
	out, _, err := lrRun(t, "n\n", "undo", lrItoa(c1))
	if err == nil || !strings.Contains(out, "two") || !strings.Contains(out, "abcdef") {
		t.Fatalf("out %q err %v", out, err)
	}
	if lrPlot(t, s, p.ID).Where != "two" {
		t.Fatal("wrote after no")
	}
	if _, _, err := lrRun(t, "y\n", "undo", lrItoa(c1)); err != nil {
		t.Fatal(err)
	}
	if lrPlot(t, s, p.ID).Where != "" {
		t.Fatal("not undone after yes")
	}
}

func TestChangesCommand(t *testing.T) {
	s, a := linkRepoEnv(t, store.PlotInput{Name: "Alpha"})
	b, err := s.CreatePlot(store.PlotInput{Name: "Beta"}, store.Actor{Kind: store.ActorCLI})
	if err != nil {
		t.Fatal(err)
	}
	c1 := edit(t, s, a.ID, store.ItemWhat, "a1")
	c2 := edit(t, s, b.Plot.ID, store.ItemWhat, "b1")
	c3 := edit(t, s, a.ID, store.ItemWhy, "a2")
	run := func(args ...string) []store.ChangeRecord {
		out, _, err := lrRun(t, "", append([]string{"changes", "--json"}, args...)...)
		if err != nil {
			t.Fatal(err)
		}
		var r struct {
			Changes []store.ChangeRecord `json:"changes"`
		}
		if err := json.Unmarshal([]byte(out), &r); err != nil {
			t.Fatalf("%s: %v", out, err)
		}
		return r.Changes
	}
	if got := run("--since", lrItoa(c1)); len(got) != 2 || got[0].ID != c2 || got[1].ID != c3 {
		t.Fatalf("since all plots: %+v", got)
	}
	got := run("Alpha")
	last := got[len(got)-1]
	if last.ID != c3 || last.PlotID != a.ID || len(last.Entries) != 1 || last.Actor.SessionID != "abcdef123" {
		t.Fatalf("plot filter, newest last: %+v", got)
	}
	for _, c := range got {
		if c.PlotID != a.ID {
			t.Fatal("other plot leaked")
		}
	}
	out, _, err := lrRun(t, "", "changes", "Alpha", "--since", lrItoa(c1))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "a2") || !strings.Contains(out, "claude abcdef") || strings.Contains(out, "a1") {
		t.Fatalf("text: %s", out)
	}
}
