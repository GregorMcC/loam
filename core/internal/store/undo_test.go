package store_test

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

var app = store.Actor{Kind: store.ActorApp}

func undo(t *testing.T, s *store.Store, id int64, overwrite bool) *store.Result {
	t.Helper()
	res, err := s.Undo(id, app, overwrite)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func TestUndoBriefField(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "a")
	r := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{
		{Op: store.OpSet, Item: store.ItemWhat, Value: "new what"},
		{Op: store.OpSet, Item: store.ItemWhy, Value: "new why"}}})
	u := undo(t, s, r.ChangeID, false)
	if u.ChangeID <= r.ChangeID || u.Plot.What != "what a" || u.Plot.Why != "why a" {
		t.Fatalf("%+v", u.Plot)
	}
	chs, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID, SinceID: r.ChangeID})
	if len(chs) != 1 || chs[0].Actor.Kind != store.ActorApp || len(chs[0].Entries) != 2 {
		t.Fatalf("%+v", chs)
	}
	all, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID})
	if len(all) != 3 {
		t.Fatalf("undo must not remove entries: %d", len(all))
	}
}

func TestUndoLinkAddUpdateRemove(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "a")
	add := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpAddLink, Label: store.S("A"), Target: store.S("https://a"), Note: store.S("n")}}})
	id := add.Added[0]
	apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpAddLink, Label: store.S("B"), Target: store.S("https://b")}}})
	upd := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpUpdateLink, Item: id, Label: store.S("A2"), Note: store.S("n2")}}})
	r := undo(t, s, upd.ChangeID, false)
	if l := r.Plot.Links[0]; l.Label != "A" || l.Note != "n" {
		t.Fatalf("%+v", l)
	}
	rm := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpRemoveLink, Item: id}}})
	if len(rm.Plot.Links) != 1 {
		t.Fatal("not removed")
	}
	r = undo(t, s, rm.ChangeID, false)
	if len(r.Plot.Links) != 2 || "link:"+r.Plot.Links[0].ID != id || r.Plot.Links[0].Label != "A" || r.Plot.Links[0].Note != "n" || r.Plot.Links[0].Position != 1 {
		t.Fatalf("restore: %+v", r.Plot.Links)
	}
	// Undo of a link add removes the link. The later update and remove clash, so overwrite.
	r = undo(t, s, add.ChangeID, true)
	if len(r.Plot.Links) != 1 || r.Plot.Links[0].Label != "B" {
		t.Fatalf("%+v", r.Plot.Links)
	}
}

func TestUndoRepos(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "a")
	add := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpAddRepo, Path: store.S("/r/one"), Note: store.S("x")}}})
	apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpAddRepo, Path: store.S("/r/two")}}})
	id := add.Added[0]
	rm := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpRemoveRepo, Item: id}}})
	if len(rm.Plot.Repos) != 1 || !rm.Plot.Repos[0].Main {
		t.Fatalf("%+v", rm.Plot.Repos)
	}
	r := undo(t, s, rm.ChangeID, false)
	if len(r.Plot.Repos) != 2 || r.Plot.MainRepo().Path != "/r/one" || r.Plot.MainRepo().Note != "x" {
		t.Fatalf("%+v", r.Plot.Repos)
	}
	upd := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpUpdateRepo, Item: id, Note: store.S("y")}}})
	r = undo(t, s, upd.ChangeID, false)
	if r.Plot.MainRepo().Note != "x" {
		t.Fatalf("%+v", r.Plot.Repos)
	}
}

func TestUndoClashReturnsLaterChanges(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "a")
	c1 := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpSet, Item: store.ItemWhere, Value: "one"}}})
	c2 := apply(t, s, store.Change{PlotID: p.ID, Actor: store.Actor{Kind: store.ActorSession, SessionID: "s1"}, Edits: []store.Edit{{Op: store.OpSet, Item: store.ItemWhere, Value: "two"}}})
	apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpSet, Item: store.ItemWhy, Value: "unrelated"}}})
	_, err := s.Undo(c1.ChangeID, app, false)
	var ce *store.UndoClashError
	if !errors.As(err, &ce) {
		t.Fatalf("err %v", err)
	}
	if ce.ChangeID != c1.ChangeID || len(ce.Later) != 1 || ce.Later[0].ID != c2.ChangeID || ce.Later[0].Actor.SessionID != "s1" {
		t.Fatalf("%+v", ce)
	}
	if len(ce.Writes) != 1 || ce.Writes[0].Item != store.ItemWhere || ce.Writes[0].New == nil || *ce.Writes[0].New != "" || *ce.Writes[0].Old != "two" {
		t.Fatalf("writes %+v", ce.Writes)
	}
	cur, _ := s.GetPlot(p.ID)
	if cur.Where != "two" {
		t.Fatal("clash wrote")
	}
	u := undo(t, s, c1.ChangeID, true)
	if u.Plot.Where != "" {
		t.Fatalf("where %q", u.Plot.Where)
	}
}

func TestUndoOfAnUndo(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "a")
	c := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpSet, Item: store.ItemWhat, Value: "x"}}})
	u := undo(t, s, c.ChangeID, false)
	r := undo(t, s, u.ChangeID, false)
	if r.Plot.What != "x" {
		t.Fatalf("redo: %q", r.Plot.What)
	}
	// The original change now has later changes on the same item.
	if _, err := s.Undo(c.ChangeID, app, false); !errors.As(err, new(*store.UndoClashError)) {
		t.Fatalf("err %v", err)
	}
}

func TestUndoOfIsRecorded(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "a")
	r := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpSet, Item: store.ItemWhat, Value: "new"}}})
	u := undo(t, s, r.ChangeID, false)
	chs, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID})
	last, orig := chs[len(chs)-1], chs[len(chs)-2]
	if last.ID != u.ChangeID || last.UndoOf == nil || *last.UndoOf != r.ChangeID {
		t.Fatalf("undo change: %+v", last)
	}
	if orig.UndoOf != nil {
		t.Fatalf("a normal change has no undo_of: %+v", orig)
	}
	b, _ := json.Marshal(orig)
	if !strings.Contains(string(b), `"undo_of":null`) {
		t.Fatalf("undo_of must be present as null: %s", b)
	}
}

func TestUndoRefusals(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "a")
	chs, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID})
	if _, err := s.Undo(chs[0].ID, app, true); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("create: %v", err)
	}
	if _, err := s.Undo(9999, app, false); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("missing: %v", err)
	}
}

func TestUndoOfEditSkipsItemRemovedLater(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "a")
	add := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpAddLink, Label: store.S("A"), Target: store.S("t")}}})
	id := add.Added[0]
	upd := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpUpdateLink, Item: id, Label: store.S("A2")}}})
	apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpRemoveLink, Item: id}}})
	r := undo(t, s, upd.ChangeID, true)
	if r.ChangeID != 0 || len(r.Plot.Links) != 0 {
		t.Fatalf("%+v", r.Plot.Links)
	}
}

func TestUndoOverwriteWhenItemIsGone(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "a")
	add := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpAddLink, Label: store.S("A"), Target: store.S("t")}}})
	apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpRemoveLink, Item: add.Added[0]}}})
	r := undo(t, s, add.ChangeID, true)
	if r.ChangeID != 0 || len(r.Plot.Links) != 0 {
		t.Fatalf("%+v", r)
	}
}
