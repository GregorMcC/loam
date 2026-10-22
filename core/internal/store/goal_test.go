package store_test

import (
	"errors"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// addWorktree records a worktree of the plot with a goal and a link.
func addWorktree(t *testing.T, s *store.Store, plotID, name, goal string, link *store.WorktreeLink) store.Worktree {
	t.Helper()
	w, err := s.AddWorktree(store.Worktree{PlotID: plotID, Repo: "/work/app", Name: name, Branch: name, Base: "origin/main",
		Path: "/home/w/app-" + name, Goal: goal, Link: link})
	if err != nil {
		t.Fatal(err)
	}
	return w
}

func setGoal(id, goal string) store.Change {
	return store.Change{Edits: []store.Edit{{Op: store.OpSetGoal, Item: store.WorktreeItem(id), Value: goal}}}
}

func TestWorktreeKeepsItsGoalAndLink(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	link := store.NewWorktreeLink("https://linear.app/example/issue/ENG-482/link-kinds", "Link kinds", "linkaaaaab")
	w := addWorktree(t, s, p.ID, "eng-482", "Link kinds for Figma", link)
	if w.Goal != "Link kinds for Figma" || w.Link == nil || w.Link.Key != "ENG-482" || w.Version != 0 {
		t.Fatalf("add: %+v %+v", w, w.Link)
	}
	got, err := s.GetWorktree(w.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Goal != w.Goal || *got.Link != *link || got.Version != 0 {
		t.Fatalf("read: %+v %+v", got, got.Link)
	}
	// A worktree with no link reads back with no link.
	plain := addWorktree(t, s, p.ID, "plain", "", nil)
	if got, _ := s.GetWorktree(plain.ID); got.Link != nil || got.Goal != "" {
		t.Fatalf("%+v", got)
	}
	// Each worktree is an item of the plot, at version 0 until its goal changes.
	pl, _ := s.GetPlot(p.ID)
	if v, ok := pl.Versions[store.WorktreeItem(w.ID)]; !ok || v != 0 {
		t.Fatalf("versions %v", pl.Versions)
	}
	if pl.Revision != p.Revision {
		t.Fatalf("adding a worktree moved the revision from %d to %d", p.Revision, pl.Revision)
	}
}

func TestNewWorktreeLinkKeys(t *testing.T) {
	for _, c := range []struct{ target, key string }{
		{"https://linear.app/example/issue/ENG-482/link-kinds", "ENG-482"},
		{"https://github.com/example/widgets/issues/57", "#57"},
		{"https://github.com/example/widgets/pull/57", ""},
		{"https://example.com/spec", ""},
	} {
		if got := store.NewWorktreeLink(c.target, "l", "").Key; got != c.key {
			t.Errorf("%s: key %q, want %q", c.target, got, c.key)
		}
	}
	if store.NewWorktreeLink("", "l", "") != nil {
		t.Error("an empty target must give no link")
	}
}

func TestSetGoalIsAChange(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	w := addWorktree(t, s, p.ID, "fix-login", "", nil)
	c := setGoal(w.ID, "Fix the login form")
	c.PlotID = p.ID
	res := apply(t, s, c)
	if res.ChangeID == 0 || res.Plot.Revision != res.ChangeID || res.Plot.Versions[store.WorktreeItem(w.ID)] != res.ChangeID {
		t.Fatalf("%+v", res)
	}
	got, _ := s.GetWorktree(w.ID)
	if got.Goal != "Fix the login form" || got.Version != res.ChangeID {
		t.Fatalf("%+v", got)
	}
	chs, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID, SinceID: res.ChangeID - 1})
	e := chs[0].Entries
	if len(e) != 1 || e[0].Item != store.WorktreeItem(w.ID) || e[0].Field != "goal" || *e[0].Old != "" || *e[0].New != "Fix the login form" {
		t.Fatalf("entries %+v", e)
	}
	// The same goal again changes nothing.
	again := setGoal(w.ID, "Fix the login form")
	again.PlotID = p.ID
	if res := apply(t, s, again); res.ChangeID != 0 {
		t.Fatalf("change %d", res.ChangeID)
	}
}

func TestSetGoalRefusesAnUnknownWorktree(t *testing.T) {
	s := openStore(t)
	p, other := newPlot(t, s, "A"), newPlot(t, s, "B")
	w := addWorktree(t, s, other.ID, "fix-login", "", nil)
	for _, id := range []string{"nosuchwtre", w.ID} { // a worktree of another plot is unknown too
		c := setGoal(id, "x")
		c.PlotID, c.Actor = p.ID, cli
		if _, err := s.Apply(c); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("%s: %v", id, err)
		}
	}
}

func TestLongGoalSavesWithAWarning(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	w := addWorktree(t, s, p.ID, "fix-login", "", nil)
	c := setGoal(w.ID, strings.Repeat("word ", 24))
	c.PlotID = p.ID
	res := apply(t, s, c)
	want := "The goal has 24 words. The soft limit is 20 words. Shorten it."
	if res.ChangeID == 0 || len(res.Warnings) != 1 || res.Warnings[0] != want {
		t.Fatalf("%d %q", res.ChangeID, res.Warnings)
	}
	if got := store.GoalWarning(strings.Repeat("word ", 20)); got != "" {
		t.Fatalf("20 words warn: %q", got)
	}
	if got := store.GoalWarning(strings.Repeat("word ", 24)); got != want {
		t.Fatalf("%q", got)
	}
}

func TestSetGoalStaleCheck(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	w := addWorktree(t, s, p.ID, "fix-login", "first", nil)
	item := store.WorktreeItem(w.ID)
	theirs := setGoal(w.ID, "theirs")
	theirs.PlotID = p.ID
	other := apply(t, s, theirs)

	mine := setGoal(w.ID, "mine")
	mine.PlotID, mine.Actor, mine.Expect = p.ID, cli, map[string]int64{item: 0}
	_, err := s.Apply(mine)
	var stale *store.StaleError
	if !errors.As(err, &stale) || len(stale.Items) != 1 {
		t.Fatalf("want StaleError, got %v", err)
	}
	it := stale.Items[0]
	if it.Item != item || !it.Exists || it.Current != other.ChangeID || it.Worktree == nil || it.Worktree.Goal != "theirs" {
		t.Fatalf("stale item %+v", it)
	}
	if got, _ := s.GetWorktree(w.ID); got.Goal != "theirs" {
		t.Fatalf("a stale write changed the goal: %q", got.Goal)
	}
	// The current version passes.
	mine.Expect[item] = other.ChangeID
	apply(t, s, mine)

	// A worktree that is gone is stale, and it does not exist.
	if err := s.RemoveWorktree(w.ID); err != nil {
		t.Fatal(err)
	}
	mine.Edits[0].Value = "gone"
	_, err = s.Apply(mine)
	if !errors.As(err, &stale) || stale.Items[0].Exists || stale.Items[0].Worktree != nil {
		t.Fatalf("got %v", err)
	}
}

func TestUndoGoal(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	w := addWorktree(t, s, p.ID, "fix-login", "first", nil)
	c := setGoal(w.ID, "second")
	c.PlotID = p.ID
	edit := apply(t, s, c)

	u := undo(t, s, edit.ChangeID, false)
	if got, _ := s.GetWorktree(w.ID); got.Goal != "first" || got.Version != u.ChangeID {
		t.Fatalf("%+v", got)
	}
	// An undo after a later goal edit clashes, and it shows the goal it would write.
	later := setGoal(w.ID, "third")
	later.PlotID = p.ID
	apply(t, s, later)
	_, err := s.Undo(edit.ChangeID, app, false)
	var ce *store.UndoClashError
	if !errors.As(err, &ce) {
		t.Fatalf("err %v", err)
	}
	if len(ce.Writes) != 1 || ce.Writes[0].Field != "goal" || *ce.Writes[0].Old != "third" || *ce.Writes[0].New != "first" {
		t.Fatalf("writes %+v", ce.Writes)
	}
}

func TestUndoGoalOfAWorktreeThatIsGoneFails(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	w := addWorktree(t, s, p.ID, "fix-login", "first", nil)
	c := setGoal(w.ID, "second")
	c.PlotID = p.ID
	edit := apply(t, s, c)
	if err := s.RemoveWorktree(w.ID); err != nil {
		t.Fatal(err)
	}
	before, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID})
	for _, overwrite := range []bool{false, true} {
		_, err := s.Undo(edit.ChangeID, app, overwrite)
		if !errors.Is(err, store.ErrNotFound) || !strings.Contains(err.Error(), "worktree") || !strings.Contains(err.Error(), "removed") {
			t.Fatalf("overwrite %v: %v", overwrite, err)
		}
	}
	if after, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID}); len(after) != len(before) {
		t.Fatalf("a failed undo wrote a change")
	}
}

// A later goal edit does not turn the undo into a clash: no overwrite can
// bring a removed worktree back, so the undo fails at once.
func TestUndoGoalOfAWorktreeThatIsGoneFailsBeforeTheClash(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	w := addWorktree(t, s, p.ID, "fix-login", "first", nil)
	first := setGoal(w.ID, "second")
	first.PlotID = p.ID
	edit := apply(t, s, first)
	later := setGoal(w.ID, "third")
	later.PlotID = p.ID
	apply(t, s, later)
	if err := s.RemoveWorktree(w.ID); err != nil {
		t.Fatal(err)
	}
	_, err := s.Undo(edit.ChangeID, app, false)
	var ce *store.UndoClashError
	if errors.As(err, &ce) || !errors.Is(err, store.ErrNotFound) || !strings.Contains(err.Error(), "removed") {
		t.Fatalf("want ErrNotFound before the clash, got %v", err)
	}
}
