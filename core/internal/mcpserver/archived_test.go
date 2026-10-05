package mcpserver_test

import (
	"encoding/json"
	"testing"
)

func TestListPlotsArchivedOption(t *testing.T) {
	e := setup(t, opts{})
	if err := e.s.SetArchived(e.other.ID, true); err != nil {
		t.Fatal(err)
	}
	type rows = []struct {
		ID       string
		Archived bool
	}
	list := func(args map[string]any) rows {
		t.Helper()
		var out struct{ Plots rows }
		if err := json.Unmarshal([]byte(e.ok("list_plots", args)), &out); err != nil {
			t.Fatal(err)
		}
		return out.Plots
	}
	if got := list(nil); len(got) != 1 || got[0].ID != e.plot.ID || got[0].Archived {
		t.Fatalf("default %+v", got)
	}
	if got := list(map[string]any{"archived": true}); len(got) != 1 || got[0].ID != e.other.ID || !got[0].Archived {
		t.Fatalf("archived %+v", got)
	}
	// An archived plot can still be read and edited. No tool archives or deletes
	// (TestListToolsAndReadOnlyHints lists every tool).
	var plot struct{ Archived bool }
	if err := json.Unmarshal([]byte(e.ok("get_plot", map[string]any{"plot": e.other.ID})), &plot); err != nil || !plot.Archived {
		t.Fatalf("get_plot does not show the flag: %v", err)
	}
	e.ok("set_what_why", map[string]any{"plot": e.other.ID, "what": "edited"})
}
