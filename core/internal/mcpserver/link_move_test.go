package mcpserver_test

import (
	"os"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
)

func addThreeLinks(t *testing.T, e *env) []string {
	t.Helper()
	var ids []string
	for _, l := range []string{"One", "Two", "Three"} {
		res, err := e.s.Apply(store.Change{PlotID: e.plot.ID, Actor: store.Actor{Kind: store.ActorCLI},
			Edits: []store.Edit{{Op: store.OpAddLink, Label: store.S(l), Target: store.S("https://example.com/" + strings.ToLower(l))}}})
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, res.Plot.Links[len(res.Plot.Links)-1].ID)
	}
	return ids
}

func TestMoveLink(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	ids := addThreeLinks(t, e)
	e.ok("get_plot", nil)
	e.ok("move_link", map[string]any{"link_id": ids[2], "position": 1})
	p := e.plotNow(e.plot.ID)
	if p.Links[0].ID != ids[2] || p.Links[1].ID != ids[0] || p.Links[2].ID != ids[1] {
		t.Fatalf("order %+v", p.Links)
	}
	b, err := os.ReadFile(seed.Path(e.s, e.plot.ID))
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	if i, j := strings.Index(s, "Three"), strings.Index(s, "One"); i < 0 || j < 0 || i > j {
		t.Fatalf("seed:\n%s", s)
	}
	if out := e.fail("move_link", map[string]any{"link_id": ids[0], "position": 9}); out == "" {
		t.Fatal("no error text")
	}
	if out := e.fail("move_link", map[string]any{"link_id": "", "position": 1}); !strings.Contains(out, "link_id is required") {
		t.Fatalf("%s", out)
	}
}

func TestMoveLinkNeedsARead(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	ids := addThreeLinks(t, e)
	if out := e.fail("move_link", map[string]any{"link_id": ids[2], "position": 1}); !strings.Contains(out, "get_plot") {
		t.Fatalf("%s", out)
	}
}

func TestMoveLinkStaleAfterOtherMove(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	ids := addThreeLinks(t, e)
	e.ok("get_plot", nil)
	if _, err := e.s.Apply(store.Change{PlotID: e.plot.ID, Actor: store.Actor{Kind: store.ActorCLI},
		Edits: []store.Edit{{Op: store.OpMoveLink, Item: store.LinkItem(ids[1]), Value: "1"}}}); err != nil {
		t.Fatal(err)
	}
	if out := e.fail("move_link", map[string]any{"link_id": ids[2], "position": 1}); !strings.Contains(out, "stale") && !strings.Contains(out, "changed") || !strings.Contains(out, store.ItemLinkOrder) {
		t.Fatalf("%s", out)
	}
}

func TestMoveLinkKeepsLinkVersions(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	ids := addThreeLinks(t, e)
	e.ok("get_plot", nil)
	e.ok("move_link", map[string]any{"link_id": ids[2], "position": 1})
	e.ok("update_link", map[string]any{"link_id": ids[0], "label": "Uno"})
}
