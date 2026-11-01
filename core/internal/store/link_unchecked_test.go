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

// undoRig holds one link on one plot for the undo tests.
type undoRig struct {
	t    *testing.T
	s    *store.Store
	plot store.Plot
	item string
}

func newUndoRig(t *testing.T, actor store.Actor) *undoRig {
	t.Helper()
	s := openStore(t)
	p := newPlot(t, s, "Alpha")
	res, err := s.Apply(store.Change{PlotID: p.ID, Actor: actor, Edits: []store.Edit{{
		Op: store.OpAddLink, Label: store.S("Docs"), Target: store.S("/first"), Note: store.S("first note"),
	}}})
	if err != nil {
		t.Fatal(err)
	}
	return &undoRig{t, s, p, res.Added[0]}
}

func (r *undoRig) edit(actor store.Actor, e store.Edit) int64 {
	r.t.Helper()
	e.Op, e.Item = store.OpUpdateLink, r.item
	res, err := r.s.Apply(store.Change{PlotID: r.plot.ID, Actor: actor, Edits: []store.Edit{e}})
	if err != nil {
		r.t.Fatal(err)
	}
	return res.ChangeID
}

func (r *undoRig) undo(id int64, actor store.Actor, overwrite bool) int64 {
	r.t.Helper()
	res, err := r.s.Undo(id, actor, overwrite)
	if err != nil {
		r.t.Fatal(err)
	}
	return res.ChangeID
}

func (r *undoRig) link() store.Link {
	r.t.Helper()
	p, err := r.s.GetPlot(r.plot.ID)
	if err != nil {
		r.t.Fatal(err)
	}
	if len(p.Links) != 1 {
		r.t.Fatalf("links %+v", p.Links)
	}
	return p.Links[0]
}

// An undo by a person of a later session change does not confirm the first
// values of the session, because no person chose them.
func TestPersonUndoDoesNotConfirmTheFirstValuesOfASession(t *testing.T) {
	for _, person := range []store.Actor{cliPerson, appPerson} {
		r := newUndoRig(t, sessionActor)
		note := r.edit(sessionActor, store.Edit{Note: store.S("second note")})
		undo := r.undo(note, person, false)
		if got := r.link(); got.Note != "first note" || !got.Unchecked {
			t.Errorf("%s: after the undo: %+v", person.Kind, got)
		}
		// The undo of that undo brings the session note back.
		r.undo(undo, person, false)
		if got := r.link(); got.Note != "second note" || !got.Unchecked {
			t.Errorf("%s: after the undo of the undo: %+v", person.Kind, got)
		}
		// A person still confirms the link with a change of their own.
		r.edit(person, store.Edit{Label: store.S("Design docs")})
		if r.link().Unchecked {
			t.Errorf("%s: a person change did not confirm the link", person.Kind)
		}
	}
}

// When a person removes a session link and undoes the removal, the link comes
// back as it was.
func TestPersonUndoOfARemovalKeepsTheLinkUnchecked(t *testing.T) {
	r := newUndoRig(t, sessionActor)
	res, err := r.s.Apply(store.Change{PlotID: r.plot.ID, Actor: cliPerson, Edits: []store.Edit{{Op: store.OpRemoveLink, Item: r.item}}})
	if err != nil {
		t.Fatal(err)
	}
	r.undo(res.ChangeID, cliPerson, false)
	if !r.link().Unchecked {
		t.Error("the undo of a removal confirmed a session link")
	}
}

// A person who confirmed a link can reject a later session change, and the link
// stays confirmed.
func TestPersonUndoKeepsAConfirmation(t *testing.T) {
	r := newUndoRig(t, sessionActor)
	confirm := r.edit(cliPerson, store.Edit{Label: store.S("Design docs")})
	target := r.edit(sessionActor, store.Edit{Target: store.S("/second")})
	r.undo(target, cliPerson, false)
	if got := r.link(); got.Target != "/first" || got.Unchecked {
		t.Errorf("after the undo of the session change: %+v", got)
	}
	// The undo of the confirmation takes the confirmation away.
	r.undo(confirm, cliPerson, true)
	if got := r.link(); got.Label != "Docs" || !got.Unchecked {
		t.Errorf("after the undo of the confirmation: %+v", got)
	}
}

// An undo with overwrite leaves the values of the later changes. So it does not
// confirm a later session value.
func TestPersonUndoWithOverwriteKeepsALaterSessionValueUnchecked(t *testing.T) {
	r := newUndoRig(t, cliPerson)
	note := r.edit(cliPerson, store.Edit{Note: store.S("second note")})
	r.edit(sessionActor, store.Edit{Target: store.S("/session")})
	r.undo(note, cliPerson, true)
	if got := r.link(); got.Note != "first note" || got.Target != "/session" || !got.Unchecked {
		t.Errorf("after the undo: %+v", got)
	}
}

// A session that undoes a change leaves the link unchecked, also when a person
// set the values that come back.
func TestSessionUndoLeavesTheLinkUnchecked(t *testing.T) {
	r := newUndoRig(t, cliPerson)
	note := r.edit(cliPerson, store.Edit{Note: store.S("second note")})
	r.undo(note, sessionActor, false)
	if got := r.link(); got.Note != "first note" || !got.Unchecked {
		t.Errorf("after the undo: %+v", got)
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
