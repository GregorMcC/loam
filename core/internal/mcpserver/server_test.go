package mcpserver_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/mcpserver"
	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	_ "modernc.org/sqlite"
)

type env struct {
	t     *testing.T
	home  string
	s     *store.Store
	cs    *mcp.ClientSession
	plot  store.Plot
	other store.Plot
}

type opts struct {
	plotEnv string // "ALPHA" means the ID of the first plot
	pid     int
	session string
}

func setup(t *testing.T, o opts) *env {
	t.Helper()
	home := testutil.Home(t)
	s, err := store.Open(home)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	mk := func(name string) store.Plot {
		r, err := s.CreatePlot(store.PlotInput{Name: name, What: "what of " + name, Why: "why", Where: "start"}, store.Actor{Kind: store.ActorCLI})
		if err != nil {
			t.Fatal(err)
		}
		return r.Plot
	}
	e := &env{t: t, home: home, s: s, plot: mk("Alpha"), other: mk("Beta")}
	if o.plotEnv == "ALPHA" {
		o.plotEnv = e.plot.ID
	}
	srv := mcpserver.New(mcpserver.Options{
		Store: s,
		PID:   o.pid,
		Getenv: func(k string) string {
			switch k {
			case "LOAM_PLOT":
				return o.plotEnv
			case "CLAUDE_CODE_SESSION_ID":
				return o.session
			}
			return ""
		},
	})
	ct, st := mcp.NewInMemoryTransports()
	ctx := context.Background()
	if _, err := srv.Connect(ctx, st, nil); err != nil {
		t.Fatal(err)
	}
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "test", Version: "0"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cs.Close() })
	e.cs = cs
	return e
}

// call returns the text of the result and whether it is an error.
func (e *env) call(name string, args map[string]any) (string, bool) {
	e.t.Helper()
	res, err := e.cs.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		e.t.Fatalf("%s: protocol error: %v", name, err)
	}
	var sb strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			sb.WriteString(tc.Text)
		}
	}
	return sb.String(), res.IsError
}

func (e *env) ok(name string, args map[string]any) string {
	e.t.Helper()
	out, isErr := e.call(name, args)
	if isErr {
		e.t.Fatalf("%s failed: %s", name, out)
	}
	return out
}

func (e *env) fail(name string, args map[string]any) string {
	e.t.Helper()
	out, isErr := e.call(name, args)
	if !isErr {
		e.t.Fatalf("%s should fail, got: %s", name, out)
	}
	return out
}

func (e *env) plotNow(id string) store.Plot {
	e.t.Helper()
	p, err := e.s.GetPlot(id)
	if err != nil {
		e.t.Fatal(err)
	}
	return p
}

func (e *env) lastChange() store.ChangeRecord {
	e.t.Helper()
	cs, err := e.s.ListChanges(store.ChangeQuery{PlotID: e.plot.ID, Newest: true, Limit: 1})
	if err != nil || len(cs) != 1 {
		e.t.Fatalf("changes: %v %v", cs, err)
	}
	return cs[0]
}

func TestListToolsAndReadOnlyHints(t *testing.T) {
	e := setup(t, opts{})
	res, err := e.cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	ro := map[string]bool{}
	for _, tl := range res.Tools {
		ro[tl.Name] = tl.Annotations != nil && tl.Annotations.ReadOnlyHint
	}
	want := map[string]bool{"list_plots": true, "get_plot": true, "get_changes": true,
		"add_link": false, "update_link": false, "remove_link": false, "set_what_why": false, "set_where_it_stands": false,
		"create_plot": false, "rename_plot": false, "add_repo": false, "update_repo": false, "remove_repo": false, "set_main_repo": false,
		"undo_change": false, "list_worktrees": true, "create_worktree": false}
	if len(ro) != len(want) {
		t.Fatalf("tools %v", ro)
	}
	for n, w := range want {
		if got, ok := ro[n]; !ok || got != w {
			t.Errorf("tool %s: present %v readOnly %v, want %v", n, ok, got, w)
		}
	}
}

func TestListPlots(t *testing.T) {
	e := setup(t, opts{})
	var out struct {
		Plots []struct{ ID, Name, What string }
	}
	if err := json.Unmarshal([]byte(e.ok("list_plots", nil)), &out); err != nil {
		t.Fatal(err)
	}
	if len(out.Plots) != 2 || out.Plots[0].ID != e.plot.ID || out.Plots[0].Name != "Alpha" || out.Plots[0].What != "what of Alpha" {
		t.Fatalf("%+v", out)
	}
}

func TestGetPlotReturnsPlotWithoutVersions(t *testing.T) {
	e := setup(t, opts{})
	out := e.ok("get_plot", map[string]any{"plot": e.plot.ID})
	if !strings.Contains(out, "what of Alpha") || strings.Contains(out, "versions") {
		t.Fatalf("%s", out)
	}
}

func TestPlotFallsBackToEnvAndFailsWithNeither(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	if out := e.ok("get_plot", nil); !strings.Contains(out, "Alpha") {
		t.Fatalf("%s", out)
	}
	if out := e.ok("get_plot", map[string]any{"plot": e.other.ID}); !strings.Contains(out, "Beta") {
		t.Fatalf("explicit plot should win: %s", out)
	}
	e2 := setup(t, opts{})
	if out := e2.fail("get_plot", nil); !strings.Contains(out, "list_plots") {
		t.Fatalf("error should name list_plots: %s", out)
	}
}

func TestPlotArgumentTakesIDsOnly(t *testing.T) {
	e := setup(t, opts{})
	if out := e.fail("get_plot", map[string]any{"plot": "Alpha"}); !strings.Contains(out, "list_plots") {
		t.Fatalf("%s", out)
	}
}

func TestWriteNeedsEarlierGetPlot(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	args := map[string]any{"label": "Doc", "target": "https://example.com"}
	if out := e.fail("add_link", args); !strings.Contains(out, "get_plot") {
		t.Fatalf("%s", out)
	}
	if n := len(e.plotNow(e.plot.ID).Links); n != 0 {
		t.Fatalf("link written without a read: %d", n)
	}
	e.ok("get_plot", nil)
	e.ok("add_link", args)
	if n := len(e.plotNow(e.plot.ID).Links); n != 1 {
		t.Fatalf("links %d", n)
	}
	// A read of one plot does not unlock another.
	e.fail("add_link", map[string]any{"plot": e.other.ID, "label": "x", "target": "https://x.test"})
}

func TestAddLinkWritesSeedAndChangeWithSessionActor(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA", session: "sess-env"})
	e.ok("get_plot", nil)
	out := e.ok("add_link", map[string]any{"label": "Doc", "target": "https://example.com", "note": "n"})
	if !strings.Contains(out, "link_id") {
		t.Fatalf("%s", out)
	}
	p := e.plotNow(e.plot.ID)
	if len(p.Links) != 1 || p.Links[0].Label != "Doc" || p.Links[0].Note != "n" {
		t.Fatalf("%+v", p.Links)
	}
	b, err := os.ReadFile(seed.Path(e.s, p.ID))
	if err != nil || !strings.Contains(string(b), "https://example.com") {
		t.Fatalf("seed: %v %s", err, b)
	}
	a := e.lastChange().Actor
	if a.Kind != store.ActorSession || a.SessionID != "sess-env" || a.LoamStarted {
		t.Fatalf("%+v", a)
	}
}

func TestActorFromParentPIDBeatsEnvAndRecordsLoamStarted(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA", pid: 4242, session: "stale-env"})
	if err := e.s.SetPIDSession(4242, "current-sess"); err != nil {
		t.Fatal(err)
	}
	if err := e.s.AddSession(store.SessionRecord{SessionID: "current-sess", PlotID: e.plot.ID, StartFolder: "/tmp"}); err != nil {
		t.Fatal(err)
	}
	e.ok("get_plot", nil)
	e.ok("add_link", map[string]any{"label": "Doc", "target": "https://example.com"})
	if a := e.lastChange().Actor; a.SessionID != "current-sess" || !a.LoamStarted {
		t.Fatalf("%+v", a)
	}
	// The record moves on after /clear: the next call sees the new session.
	if err := e.s.SetPIDSession(4242, "after-clear"); err != nil {
		t.Fatal(err)
	}
	e.ok("add_link", map[string]any{"label": "Two", "target": "https://two.test"})
	if a := e.lastChange().Actor; a.SessionID != "after-clear" || a.LoamStarted {
		t.Fatalf("%+v", a)
	}
}

func TestUpdateAndRemoveLink(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	e.ok("add_link", map[string]any{"label": "Doc", "target": "https://example.com"})
	id := e.plotNow(e.plot.ID).Links[0].ID
	// The server knows the new link, so a write that follows needs no second read.
	e.ok("update_link", map[string]any{"link_id": id, "label": "Docs", "note": "later"})
	l := e.plotNow(e.plot.ID).Links[0]
	if l.Label != "Docs" || l.Note != "later" || l.Target != "https://example.com" {
		t.Fatalf("%+v", l)
	}
	e.ok("remove_link", map[string]any{"link_id": id})
	if n := len(e.plotNow(e.plot.ID).Links); n != 0 {
		t.Fatalf("links %d", n)
	}
}

func TestSetWhatWhyAndWhere(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	e.ok("set_what_why", map[string]any{"what": "new what"})
	p := e.plotNow(e.plot.ID)
	if p.What != "new what" || p.Why != "why" {
		t.Fatalf("%+v", p)
	}
	e.fail("set_what_why", map[string]any{})
	e.ok("set_where_it_stands", map[string]any{"text": "halfway"})
	if got := e.plotNow(e.plot.ID).Where; got != "halfway" {
		t.Fatalf("where %q", got)
	}
}

func TestLongBriefReturnsWarning(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	out := e.ok("set_where_it_stands", map[string]any{"text": strings.Repeat("word ", 400)})
	if !strings.Contains(out, "warnings") {
		t.Fatalf("%s", out)
	}
}

func TestStaleWriteFailsWithCurrentValues(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	set := func(item, v string) {
		t.Helper()
		_, err := e.s.Apply(store.Change{PlotID: e.plot.ID, Actor: store.Actor{Kind: store.ActorApp},
			Edits: []store.Edit{{Op: store.OpSet, Item: item, Value: v}}})
		if err != nil {
			t.Fatal(err)
		}
	}
	set(store.ItemWhere, "changed elsewhere")
	out := e.fail("set_where_it_stands", map[string]any{"text": "mine"})
	if !strings.Contains(out, "changed elsewhere") || !strings.Contains(out, "get_plot") {
		t.Fatalf("%s", out)
	}
	if got := e.plotNow(e.plot.ID).Where; got != "changed elsewhere" {
		t.Fatalf("stale write went through: %q", got)
	}
	e.ok("get_plot", nil)
	e.ok("set_where_it_stands", map[string]any{"text": "mine"})
	// A change to a field this write does not touch is not stale.
	set(store.ItemWhy, "other")
	e.ok("set_where_it_stands", map[string]any{"text": "mine again"})
}

func TestGetChanges(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	e.ok("set_where_it_stands", map[string]any{"text": "one"})
	e.ok("set_where_it_stands", map[string]any{"text": "two"})
	var out struct {
		Changes []struct {
			ID      int64
			Entries []struct{ New *string }
		}
	}
	if err := json.Unmarshal([]byte(e.ok("get_changes", map[string]any{"limit": 1})), &out); err != nil {
		t.Fatal(err)
	}
	if len(out.Changes) != 1 || *out.Changes[0].Entries[0].New != "two" {
		t.Fatalf("%+v", out)
	}
	out.Changes = nil
	if err := json.Unmarshal([]byte(e.ok("get_changes", nil)), &out); err != nil {
		t.Fatal(err)
	}
	if len(out.Changes) != 3 || out.Changes[0].ID < out.Changes[1].ID {
		t.Fatalf("want 3 changes, newest first: %+v", out)
	}
}

func TestSchemaNewerFailsWritesWithRestartMessage(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	db, err := sql.Open("sqlite", filepath.Join(e.home, "loam.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`UPDATE schema_version SET version = ?`, store.SchemaVersion+1); err != nil {
		t.Fatal(err)
	}
	if out := e.fail("set_where_it_stands", map[string]any{"text": "x"}); !strings.Contains(out, "restart this session") {
		t.Fatalf("%s", out)
	}
	e.ok("get_plot", nil)
}
