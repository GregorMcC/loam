package store_test

import (
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

var (
	sessionActor = store.Actor{Kind: store.ActorSession, SessionID: "s1"}
	cliPerson    = store.Actor{Kind: store.ActorCLI}
	appPerson    = store.Actor{Kind: store.ActorApp}
)

// A link is unchecked when a session made the last change to it. Each step
// writes a real change, and the store reads the answer from the change log.
func TestLinkUncheckedFollowsTheLastChange(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Alpha")
	res, err := s.Apply(store.Change{PlotID: p.ID, Actor: sessionActor, Edits: []store.Edit{{
		Op: store.OpAddLink, Label: store.S("Docs"), Target: store.S("/docs"), Note: store.S("read this"),
	}}})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Plot.Links) != 1 || !res.Plot.Links[0].Unchecked {
		t.Fatalf("a link that a session added: %+v", res.Plot.Links)
	}
	item := store.LinkItem(res.Plot.Links[0].ID)
	check := func(step string, want bool) {
		t.Helper()
		got, err := s.GetPlot(p.ID)
		if err != nil {
			t.Fatal(err)
		}
		if got.Links[0].Unchecked != want {
			t.Errorf("%s: Unchecked = %v, want %v", step, got.Links[0].Unchecked, want)
		}
	}
	edit := func(actor store.Actor, e store.Edit) *store.Result {
		t.Helper()
		e.Op, e.Item = store.OpUpdateLink, item
		res, err := s.Apply(store.Change{PlotID: p.ID, Actor: actor, Edits: []store.Edit{e}})
		if err != nil {
			t.Fatal(err)
		}
		return res
	}

	// An edit that changes no value records nothing, so it confirms nothing.
	if res := edit(cliPerson, store.Edit{Target: store.S("/docs"), Note: store.S("read this")}); res.ChangeID != 0 {
		t.Errorf("an edit with the same values wrote change %d", res.ChangeID)
	}
	check("a person edit with the same values", true)

	// A label edit keeps the target and the note, and it is still a change.
	edit(cliPerson, store.Edit{Label: store.S("Design docs")})
	check("a person changed the label", false)

	edit(sessionActor, store.Edit{Target: store.S("/other")})
	check("a session changed the target", true)

	edit(appPerson, store.Edit{Note: store.S("checked")})
	check("a person in the app changed the note", false)
}

// An undo is a change by its actor, so the actor of the undo decides.
func TestLinkUncheckedAfterAnUndo(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Alpha")
	res, err := s.Apply(store.Change{PlotID: p.ID, Actor: cliPerson, Edits: []store.Edit{{
		Op: store.OpAddLink, Label: store.S("Docs"), Target: store.S("/docs"),
	}}})
	if err != nil {
		t.Fatal(err)
	}
	if res.Plot.Links[0].Unchecked {
		t.Fatal("a link that a person added is unchecked")
	}
	item := store.LinkItem(res.Plot.Links[0].ID)
	change, err := s.Apply(store.Change{PlotID: p.ID, Actor: sessionActor, Edits: []store.Edit{{
		Op: store.OpUpdateLink, Item: item, Target: store.S("/secret"),
	}}})
	if err != nil {
		t.Fatal(err)
	}
	if !change.Plot.Links[0].Unchecked {
		t.Fatal("a link that a session changed is not unchecked")
	}
	undone, err := s.Undo(change.ChangeID, cliPerson, false)
	if err != nil {
		t.Fatal(err)
	}
	if got := undone.Plot.Links[0]; got.Target != "/docs" || got.Unchecked {
		t.Errorf("after a person undo: %+v", got)
	}
	redo, err := s.Undo(undone.ChangeID, sessionActor, false)
	if err != nil {
		t.Fatal(err)
	}
	if got := redo.Plot.Links[0]; got.Target != "/secret" || !got.Unchecked {
		t.Errorf("after a session undo: %+v", got)
	}
}

// A plot that a session creates holds unchecked links, and one that a person
// creates does not.
func TestLinkUncheckedOnANewPlot(t *testing.T) {
	s := openStore(t)
	links := []store.LinkInput{{Label: "Docs", Target: "/docs"}}
	bySession, err := s.CreatePlot(store.PlotInput{Name: "By session", Links: links}, sessionActor)
	if err != nil {
		t.Fatal(err)
	}
	if !bySession.Plot.Links[0].Unchecked {
		t.Error("a link in a plot that a session created is not unchecked")
	}
	byPerson, err := s.CreatePlot(store.PlotInput{Name: "By person", Links: links}, cliPerson)
	if err != nil {
		t.Fatal(err)
	}
	if byPerson.Plot.Links[0].Unchecked {
		t.Error("a link in a plot that a person created is unchecked")
	}
}
