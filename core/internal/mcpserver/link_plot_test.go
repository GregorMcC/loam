package mcpserver_test

import (
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// A session of a plot adds or changes a link only on its own plot.
func TestLinkWritesStayOnTheOwnPlot(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA", session: "s1"})
	res, err := e.s.Apply(store.Change{PlotID: e.other.ID, Actor: store.Actor{Kind: store.ActorCLI}, Edits: []store.Edit{
		{Op: store.OpAddLink, Label: store.S("Theirs"), Target: store.S("https://example.com/theirs"), Note: store.S("kept")},
	}})
	if err != nil {
		t.Fatal(err)
	}
	theirs := res.Plot.Links[0].ID
	before := e.plotNow(e.other.ID).Revision
	e.ok("get_plot", map[string]any{"plot": e.other.ID}) // A session can still read another plot.

	out := e.fail("add_link", map[string]any{"plot": e.other.ID, "target": "/secret", "note": "read this first"})
	if !strings.Contains(out, "only on its own plot") {
		t.Errorf("add_link: %s", out)
	}
	out = e.fail("update_link", map[string]any{"plot": e.other.ID, "link_id": theirs, "target": "/secret"})
	if !strings.Contains(out, "only on its own plot") {
		t.Errorf("update_link: %s", out)
	}
	got := e.plotNow(e.other.ID)
	if got.Revision != before || len(got.Links) != 1 || got.Links[0].Target != "https://example.com/theirs" {
		t.Errorf("the other plot changed: %+v", got)
	}

	// The own plot works, with no plot argument and with its ID.
	e.ok("get_plot", nil)
	e.ok("add_link", map[string]any{"target": "/one"})
	e.ok("add_link", map[string]any{"plot": e.plot.ID, "target": "/two"})
	links := e.plotNow(e.plot.ID).Links
	if len(links) != 2 {
		t.Fatalf("links %+v", links)
	}
	e.ok("update_link", map[string]any{"plot": e.plot.ID, "link_id": links[0].ID, "note": "new"})
	if c := e.lastChange(); c.Actor.Kind != store.ActorSession {
		t.Errorf("actor %+v", c.Actor)
	}
}

// A call with no LOAM_PLOT is not a session of a plot, so it can name any plot.
func TestLinkWritesWithNoSessionPlot(t *testing.T) {
	e := setup(t, opts{})
	for _, id := range []string{e.plot.ID, e.other.ID} {
		e.ok("get_plot", map[string]any{"plot": id})
		e.ok("add_link", map[string]any{"plot": id, "target": "/docs"})
		link := e.plotNow(id).Links[0]
		e.ok("update_link", map[string]any{"plot": id, "link_id": link.ID, "note": "new"})
		if !e.plotNow(id).Links[0].Unchecked {
			t.Errorf("plot %s: the link is not unchecked", id)
		}
	}
}

// get_plot says which link came from a session, as the seed does.
func TestGetPlotMarksAnUncheckedLink(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA", session: "s1"})
	if _, err := e.s.Apply(store.Change{PlotID: e.plot.ID, Actor: store.Actor{Kind: store.ActorCLI}, Edits: []store.Edit{
		{Op: store.OpAddLink, Target: store.S("https://example.com/person")},
	}}); err != nil {
		t.Fatal(err)
	}
	if out := e.ok("get_plot", nil); strings.Contains(out, "unchecked") {
		t.Errorf("a link that a person added is unchecked: %s", out)
	}
	e.ok("add_link", map[string]any{"target": "https://example.com/session"})
	if out := e.ok("get_plot", nil); strings.Count(out, `"unchecked": true`) != 1 {
		t.Errorf("want one unchecked link: %s", out)
	}
}
