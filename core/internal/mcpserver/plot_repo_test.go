package mcpserver_test

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
)

func idOut(t *testing.T, out, key string) string {
	t.Helper()
	m := map[string]any{}
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	s, _ := m[key].(string)
	if s == "" {
		t.Fatalf("no %s in %s", key, out)
	}
	return s
}

func TestCreatePlotNeedsNoGetPlotAndWritesSeed(t *testing.T) {
	r1, r2 := t.TempDir(), t.TempDir()
	e := setup(t, opts{session: "sess-x"})
	out := e.ok("create_plot", map[string]any{
		"name": "Gamma", "what": "w", "why": "y", "where_it_stands": "begin",
		"links": []map[string]any{{"label": "Doc", "target": "https://example.com"}},
		"repos": []map[string]any{{"path": r1, "note": "first"}, {"path": r2}},
	})
	id := idOut(t, out, "plot_id")
	p := e.plotNow(id)
	if p.Name != "Gamma" || p.What != "w" || p.Where != "begin" || len(p.Links) != 1 || len(p.Repos) != 2 || !p.Repos[0].Main {
		t.Fatalf("%+v", p)
	}
	if _, err := os.Stat(seed.Path(e.s, id)); err != nil {
		t.Fatalf("no seed: %v", err)
	}
	cs, _ := e.s.ListChanges(store.ChangeQuery{PlotID: id, Limit: 5})
	if len(cs) != 1 || cs[0].Actor.Kind != store.ActorSession || cs[0].Actor.SessionID != "sess-x" {
		t.Fatalf("%+v", cs)
	}
	// The creator can write at once, without get_plot.
	e.ok("add_link", map[string]any{"plot": id, "label": "More", "target": "https://example.org"})
}

func TestCreatePlotFailsOnBadInput(t *testing.T) {
	e := setup(t, opts{})
	e.fail("create_plot", map[string]any{"name": "", "what": "w", "why": "y"})
	e.fail("create_plot", map[string]any{"name": "N", "what": "w", "why": "y",
		"repos": []map[string]any{{"path": "relative/path"}}})
	if pl, _ := e.s.ListPlots(); len(pl) != 2 {
		t.Fatalf("plot made on failure: %d", len(pl))
	}
}

func TestRenamePlot(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.fail("rename_plot", map[string]any{"name": "New"})
	e.ok("get_plot", nil)
	e.ok("rename_plot", map[string]any{"name": "New"})
	if got := e.plotNow(e.plot.ID).Name; got != "New" {
		t.Fatalf("%q", got)
	}
	e.fail("rename_plot", map[string]any{"name": ""})
	// stale
	if _, err := e.s.Apply(store.Change{PlotID: e.plot.ID, Actor: store.Actor{Kind: store.ActorApp},
		Edits: []store.Edit{{Op: store.OpSet, Item: store.ItemName, Value: "Elsewhere"}}}); err != nil {
		t.Fatal(err)
	}
	out := e.fail("rename_plot", map[string]any{"name": "Mine"})
	if !strings.Contains(out, "Elsewhere") || !strings.Contains(out, "get_plot") {
		t.Fatalf("%s", out)
	}
}

func repoIDs(p store.Plot) (main string, others []string) {
	for _, r := range p.Repos {
		if r.Main {
			main = r.ID
		} else {
			others = append(others, r.ID)
		}
	}
	return
}

func TestAddAndUpdateRepo(t *testing.T) {
	r1, r2 := t.TempDir(), t.TempDir()
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.fail("add_repo", map[string]any{"path": r1})
	e.ok("get_plot", nil)
	id1 := idOut(t, e.ok("add_repo", map[string]any{"path": r1, "note": "a"}), "repo_id")
	e.ok("add_repo", map[string]any{"path": r2})
	p := e.plotNow(e.plot.ID)
	if len(p.Repos) != 2 || !p.Repos[0].Main || p.Repos[1].Main {
		t.Fatalf("first repo should be main: %+v", p.Repos)
	}
	e.fail("add_repo", map[string]any{"path": "rel"})
	e.fail("add_repo", map[string]any{"path": r1})
	e.ok("update_repo", map[string]any{"repo_id": id1, "note": "b"})
	if got := e.plotNow(e.plot.ID).Repos[0].Note; got != "b" {
		t.Fatalf("%q", got)
	}
	e.fail("update_repo", map[string]any{"repo_id": "nope", "note": "x"})
	if _, err := os.Stat(seed.Path(e.s, e.plot.ID)); err != nil {
		t.Fatal(err)
	}
}

func TestSetMainRepoThenWriteAgain(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	e.ok("add_repo", map[string]any{"path": t.TempDir()})
	e.ok("add_repo", map[string]any{"path": t.TempDir()})
	p := e.plotNow(e.plot.ID)
	oldMain, others := repoIDs(p)
	e.ok("set_main_repo", map[string]any{"repo_id": others[0]})
	if m, _ := repoIDs(e.plotNow(e.plot.ID)); m != others[0] {
		t.Fatalf("main %s", m)
	}
	// The old main repo changed in the same call, so a later write on it is not stale.
	e.ok("update_repo", map[string]any{"repo_id": oldMain, "note": "old"})
	e.fail("set_main_repo", map[string]any{"repo_id": "nope"})
}

func TestRemoveRepoMainRules(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	for i := 0; i < 4; i++ {
		e.ok("add_repo", map[string]any{"path": t.TempDir()})
	}
	main, others := repoIDs(e.plotNow(e.plot.ID))

	// Removing a repo that is not main is fine.
	e.ok("remove_repo", map[string]any{"repo_id": others[1]})

	// Removing main with 2 repos left needs a new main.
	out := e.fail("remove_repo", map[string]any{"repo_id": main})
	if !strings.Contains(out, "set_main_repo") || !strings.Contains(out, "new_main_repo_id") {
		t.Fatalf("%s", out)
	}
	if len(e.plotNow(e.plot.ID).Repos) != 3 {
		t.Fatal("repo removed on failure")
	}
	// The new main must be another repo of the plot.
	e.fail("remove_repo", map[string]any{"repo_id": main, "new_main_repo_id": main})

	e.ok("remove_repo", map[string]any{"repo_id": main, "new_main_repo_id": others[0]})
	p := e.plotNow(e.plot.ID)
	if m, rest := repoIDs(p); len(p.Repos) != 2 || m != others[0] || len(rest) != 1 {
		t.Fatalf("%+v", p.Repos)
	}
	// Removing the last repos works.
	e.ok("remove_repo", map[string]any{"repo_id": others[0]})
	e.ok("remove_repo", map[string]any{"repo_id": p.Repos[1].ID})
	if n := len(e.plotNow(e.plot.ID).Repos); n != 0 {
		t.Fatalf("%d", n)
	}
}

func TestRemoveRepoWithNewMainIsOneChange(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	for i := 0; i < 3; i++ {
		e.ok("add_repo", map[string]any{"path": t.TempDir()})
	}
	main, others := repoIDs(e.plotNow(e.plot.ID))
	before, _ := e.s.ListChanges(store.ChangeQuery{PlotID: e.plot.ID})
	e.ok("remove_repo", map[string]any{"repo_id": main, "new_main_repo_id": others[0]})
	after, _ := e.s.ListChanges(store.ChangeQuery{PlotID: e.plot.ID})
	if len(after) != len(before)+1 {
		t.Fatalf("changes %d -> %d", len(before), len(after))
	}
}

func TestRemoveMainWithOneRepoLeftPromotesIt(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	e.ok("add_repo", map[string]any{"path": t.TempDir()})
	e.ok("add_repo", map[string]any{"path": t.TempDir()})
	main, others := repoIDs(e.plotNow(e.plot.ID))
	e.ok("remove_repo", map[string]any{"repo_id": main})
	// The promoted repo changed in that call, so a later write is not stale.
	e.ok("update_repo", map[string]any{"repo_id": others[0], "note": "now main"})
	if m, _ := repoIDs(e.plotNow(e.plot.ID)); m != others[0] {
		t.Fatalf("main %s", m)
	}
}

func TestRepoWriteIsStale(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	id := idOut(t, e.ok("add_repo", map[string]any{"path": t.TempDir()}), "repo_id")
	if _, err := e.s.Apply(store.Change{PlotID: e.plot.ID, Actor: store.Actor{Kind: store.ActorApp},
		Edits: []store.Edit{{Op: store.OpUpdateRepo, Item: store.RepoItem(id), Note: store.S("app note")}}}); err != nil {
		t.Fatal(err)
	}
	out := e.fail("update_repo", map[string]any{"repo_id": id, "note": "mine"})
	if !strings.Contains(out, "app note") || !strings.Contains(out, "get_plot") {
		t.Fatalf("%s", out)
	}
	e.fail("remove_repo", map[string]any{"repo_id": id})
	e.ok("get_plot", nil)
	e.ok("remove_repo", map[string]any{"repo_id": id})
}
