package mcpserver_test

import (
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func TestUndoChangeTool(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA", session: "sess-1"})
	e.ok("get_plot", nil)
	e.ok("set_where_it_stands", map[string]any{"text": "one"})
	first := e.lastChange().ID
	e.ok("get_plot", nil)
	e.ok("set_where_it_stands", map[string]any{"text": "two"})

	out := e.fail("undo_change", map[string]any{"change_id": first})
	if !strings.Contains(out, "later_changes") || !strings.Contains(out, "overwrite") {
		t.Fatalf("clash result: %s", out)
	}
	if e.plotNow(e.plot.ID).Where != "two" {
		t.Fatal("clash wrote")
	}

	e.ok("undo_change", map[string]any{"change_id": first, "overwrite": true})
	if e.plotNow(e.plot.ID).Where != "start" {
		t.Fatalf("where %q", e.plotNow(e.plot.ID).Where)
	}
	if lc := e.lastChange(); lc.Actor.Kind != store.ActorSession || lc.Actor.SessionID != "sess-1" {
		t.Fatalf("actor %+v", lc.Actor)
	}

	e.ok("get_plot", nil)
	e.ok("set_what_why", map[string]any{"what": "changed"})
	e.ok("undo_change", map[string]any{"change_id": e.lastChange().ID})
	if e.plotNow(e.plot.ID).What != "what of Alpha" {
		t.Fatal("not undone")
	}
	e.fail("undo_change", map[string]any{})
}
