package store_test

import (
	"bytes"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
	_ "modernc.org/sqlite"
)

var cli = store.Actor{Kind: store.ActorCLI}

func apply(t *testing.T, s *store.Store, c store.Change) *store.Result {
	t.Helper()
	if c.Actor.Kind == "" {
		c.Actor = cli
	}
	res, err := s.Apply(c)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func TestListPlotsKeepsCreationOrder(t *testing.T) {
	s := openStore(t)
	var want []string
	for _, n := range []string{"b", "a", "c"} {
		want = append(want, newPlot(t, s, n).ID)
	}
	got, err := s.ListPlots()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Fatalf("got %d plots", len(got))
	}
	for i := range want {
		if got[i].ID != want[i] {
			t.Fatalf("position %d: got %s, want %s", i, got[i].ID, want[i])
		}
	}
	if got[0].Name != "b" || got[0].What != "what b" {
		t.Fatalf("summary %+v", got[0])
	}
}

func TestPlotFolderIsCreated(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "x")
	if fi, err := os.Stat(filepath.Join(s.Home(), "plots", p.ID)); err != nil || !fi.IsDir() {
		t.Fatalf("plot folder missing: %v", err)
	}
}

func TestIDsAreBase32(t *testing.T) {
	s := openStore(t)
	re := regexp.MustCompile(`^[a-z2-7]{10}$`)
	seen := map[string]bool{}
	for range 30 {
		id := newPlot(t, s, "p").ID
		if !re.MatchString(id) || seen[id] {
			t.Fatalf("bad or repeated ID %q", id)
		}
		seen[id] = true
	}
}

func TestChangeWithSeveralEntries(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Loam")
	actor := store.Actor{Kind: store.ActorSession, SessionID: "sess-1", LoamStarted: true}
	res := apply(t, s, store.Change{PlotID: p.ID, Actor: actor, Edits: []store.Edit{
		{Op: store.OpSet, Item: store.ItemWhere, Value: "building"},
		{Op: store.OpSet, Item: store.ItemWhat, Value: "new what"},
		{Op: store.OpAddLink, Label: store.S("Spec"), Target: store.S("https://example.com"), Note: store.S("the spec")},
	}})
	if res.ChangeID <= p.Revision {
		t.Fatalf("change ID %d not above %d", res.ChangeID, p.Revision)
	}
	if len(res.Added) != 1 || store.LinkItem(res.Plot.Links[0].ID) != res.Added[0] {
		t.Fatalf("added %v, links %+v", res.Added, res.Plot.Links)
	}
	if res.Plot.Versions[store.ItemWhere] != res.ChangeID || res.Plot.Versions[store.ItemName] != p.Revision {
		t.Fatalf("versions %v", res.Plot.Versions)
	}
	if res.Plot.Revision != res.ChangeID {
		t.Fatalf("revision %d", res.Plot.Revision)
	}
	chs, err := s.ListChanges(store.ChangeQuery{PlotID: p.ID, SinceID: p.Revision})
	if err != nil || len(chs) != 1 {
		t.Fatalf("changes %v %v", chs, err)
	}
	c := chs[0]
	if c.Actor != actor || c.ID != res.ChangeID {
		t.Fatalf("change %+v", c)
	}
	// where, what, then link label, target, note, position
	if len(c.Entries) != 6 {
		t.Fatalf("got %d entries: %+v", len(c.Entries), c.Entries)
	}
	e := c.Entries[0]
	if e.Item != "where" || e.Old == nil || *e.Old != "" || *e.New != "building" {
		t.Fatalf("first entry %+v", e)
	}
	if e := c.Entries[2]; e.Old != nil || e.New == nil {
		t.Fatalf("link entry should have a nil old value: %+v", e)
	}
}

func TestNoOpChangeWritesNothing(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Loam")
	res := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpSet, Item: store.ItemWhat, Value: p.What}}})
	if res.ChangeID != 0 {
		t.Fatalf("change ID %d", res.ChangeID)
	}
	chs, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID})
	if len(chs) != 1 {
		t.Fatalf("got %d changes, want only the create", len(chs))
	}
}

func TestListChangesNewestFirstWithLimit(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Loam")
	for _, v := range []string{"1", "2", "3"} {
		apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpSet, Item: store.ItemWhere, Value: v}}})
	}
	chs, err := s.ListChanges(store.ChangeQuery{PlotID: p.ID, Newest: true, Limit: 2})
	if err != nil || len(chs) != 2 || chs[0].ID < chs[1].ID || *chs[0].Entries[0].New != "3" {
		t.Fatalf("changes %+v %v", chs, err)
	}
}

func TestStaleWriteFailsWithCurrentValuesAndWritesNothing(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Loam")
	// Another writer sets "where" after the first writer read it.
	other := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpSet, Item: store.ItemWhere, Value: "theirs"}}})

	_, err := s.Apply(store.Change{
		PlotID: p.ID, Actor: cli,
		Expect: map[string]int64{store.ItemWhere: p.Versions[store.ItemWhere], store.ItemWhat: p.Versions[store.ItemWhat]},
		Edits: []store.Edit{
			{Op: store.OpSet, Item: store.ItemWhat, Value: "mine"},
			{Op: store.OpSet, Item: store.ItemWhere, Value: "mine"},
		},
	})
	var stale *store.StaleError
	if !errors.As(err, &stale) {
		t.Fatalf("want StaleError, got %v", err)
	}
	if len(stale.Items) != 1 {
		t.Fatalf("items %+v", stale.Items)
	}
	it := stale.Items[0]
	if it.Item != "where" || it.Value != "theirs" || it.Current != other.ChangeID || it.Expected != p.Versions["where"] {
		t.Fatalf("stale item %+v", it)
	}
	got, _ := s.GetPlot(p.ID)
	if got.What != p.What || got.Where != "theirs" {
		t.Fatalf("a stale write changed the plot: %+v", got)
	}
}

func TestExpectCurrentVersionSucceeds(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Loam")
	apply(t, s, store.Change{PlotID: p.ID, Expect: map[string]int64{"what": p.Versions["what"]},
		Edits: []store.Edit{{Op: store.OpSet, Item: "what", Value: "x"}}})
}

func TestStaleOnRemovedLink(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Loam")
	r := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpAddLink, Label: store.S("a"), Target: store.S("b")}}})
	item := r.Added[0]
	ver := r.Plot.Versions[item]
	rm := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpRemoveLink, Item: item}}})
	_, err := s.Apply(store.Change{PlotID: p.ID, Expect: map[string]int64{item: ver},
		Edits: []store.Edit{{Op: store.OpUpdateLink, Item: item, Note: store.S("n")}}})
	var stale *store.StaleError
	if !errors.As(err, &stale) || stale.Items[0].Exists || stale.Items[0].Current != rm.ChangeID {
		t.Fatalf("got %v", err)
	}
}

func TestLinkEditAndRemove(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Loam")
	r := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{
		{Op: store.OpAddLink, Label: store.S("one"), Target: store.S("t1")},
		{Op: store.OpAddLink, Label: store.S("two"), Target: store.S("t2")},
	}})
	if len(r.Plot.Links) != 2 || r.Plot.Links[0].Label != "one" || r.Plot.Links[1].Label != "two" {
		t.Fatalf("links %+v", r.Plot.Links)
	}
	first := store.LinkItem(r.Plot.Links[0].ID)
	u := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpUpdateLink, Item: first, Label: store.S("uno"), Note: store.S("n")}}})
	if u.Plot.Links[0].Label != "uno" || u.Plot.Links[0].Note != "n" || u.Plot.Links[0].Version != u.ChangeID || u.Plot.Links[1].Version != r.ChangeID {
		t.Fatalf("links %+v", u.Plot.Links)
	}
	d := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpRemoveLink, Item: first}}})
	if len(d.Plot.Links) != 1 || d.Plot.Links[0].Label != "two" {
		t.Fatalf("links %+v", d.Plot.Links)
	}
	if _, err := s.Apply(store.Change{PlotID: p.ID, Actor: cli, Edits: []store.Edit{{Op: store.OpRemoveLink, Item: first}}}); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("want not found, got %v", err)
	}
}

func TestInvalidEdits(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Loam")
	for name, e := range map[string]store.Edit{
		"empty name":     {Op: store.OpSet, Item: "name", Value: " "},
		"bad item":       {Op: store.OpSet, Item: "nope", Value: "x"},
		"link no target": {Op: store.OpAddLink, Label: store.S("a")},
		"relative repo":  {Op: store.OpAddRepo, Path: store.S("rel/path")},
		"unknown op":     {Op: "dance"},
	} {
		if _, err := s.Apply(store.Change{PlotID: p.ID, Actor: cli, Edits: []store.Edit{e}}); !errors.Is(err, store.ErrInvalid) {
			t.Errorf("%s: got %v", name, err)
		}
	}
	if _, err := s.CreatePlot(store.PlotInput{Name: ""}, cli); !errors.Is(err, store.ErrInvalid) {
		t.Errorf("empty plot name: %v", err)
	}
}

func TestBriefOverLimitWarns(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Loam")
	res := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpSet, Item: "what", Value: strings.Repeat("word ", 301)}}})
	if len(res.Warnings) != 1 {
		t.Fatalf("warnings %v", res.Warnings)
	}
	if res := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpSet, Item: "what", Value: "short"}}}); len(res.Warnings) != 0 {
		t.Fatalf("warnings %v", res.Warnings)
	}
}

func TestMainRepoRules(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Loam")
	add := func(path string) store.Plot {
		return apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpAddRepo, Path: store.S(path), Note: store.S("n")}}}).Plot
	}
	main := func(p store.Plot) string {
		if m := p.MainRepo(); m != nil {
			return m.Path
		}
		return ""
	}
	id := func(p store.Plot, path string) string {
		for _, r := range p.Repos {
			if r.Path == path {
				return store.RepoItem(r.ID)
			}
		}
		t.Fatalf("no repo %s", path)
		return ""
	}
	// The first repo becomes main. Later ones do not.
	p1 := add("/r/a")
	if main(p1) != "/r/a" {
		t.Fatal("first repo is not main")
	}
	p2 := add("/r/b/")
	if main(p2) != "/r/a" || len(p2.Repos) != 2 || p2.Repos[1].Path != "/r/b" {
		t.Fatalf("repos %+v", p2.Repos)
	}
	p3 := add("/r/c")
	// A duplicate path fails.
	if _, err := s.Apply(store.Change{PlotID: p.ID, Actor: cli, Edits: []store.Edit{{Op: store.OpAddRepo, Path: store.S("/r/c")}}}); !errors.Is(err, store.ErrDuplicate) {
		t.Fatalf("got %v", err)
	}
	// Removing main with 2 left needs a pick, and writes nothing.
	rm := store.Edit{Op: store.OpRemoveRepo, Item: id(p3, "/r/a")}
	if _, err := s.Apply(store.Change{PlotID: p.ID, Actor: cli, Edits: []store.Edit{rm}}); !errors.Is(err, store.ErrNeedMainRepo) {
		t.Fatalf("got %v", err)
	}
	if got, _ := s.GetPlot(p.ID); len(got.Repos) != 3 || main(got) != "/r/a" {
		t.Fatalf("failed change wrote: %+v", got.Repos)
	}
	// With a pick in the same change, it works.
	p4 := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{rm, {Op: store.OpSetMainRepo, Item: id(p3, "/r/c")}}}).Plot
	if main(p4) != "/r/c" || len(p4.Repos) != 2 {
		t.Fatalf("repos %+v", p4.Repos)
	}
	// Set main on its own moves the flag and bumps both versions.
	bID := id(p4, "/r/b")
	r5 := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpSetMainRepo, Item: bID}}})
	if main(r5.Plot) != "/r/b" || r5.Plot.Versions[bID] != r5.ChangeID || r5.Plot.Versions[id(p4, "/r/c")] != r5.ChangeID {
		t.Fatalf("plot %+v", r5.Plot)
	}
	// Removing main with 1 left promotes it.
	p6 := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpRemoveRepo, Item: bID}}}).Plot
	if main(p6) != "/r/c" || len(p6.Repos) != 1 {
		t.Fatalf("repos %+v", p6.Repos)
	}
	// Removing the last repo leaves none.
	p7 := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpRemoveRepo, Item: id(p6, "/r/c")}}}).Plot
	if len(p7.Repos) != 0 || p7.MainRepo() != nil {
		t.Fatalf("repos %+v", p7.Repos)
	}
}

func TestCreatePlotWithLinksAndRepos(t *testing.T) {
	s := openStore(t)
	res, err := s.CreatePlot(store.PlotInput{
		Name:  "P",
		Links: []store.LinkInput{{Label: "l", Target: "t"}},
		Repos: []store.RepoInput{{Path: "/r/a"}, {Path: "/r/b"}},
	}, cli)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Plot.Links) != 1 || len(res.Plot.Repos) != 2 || res.Plot.MainRepo().Path != "/r/a" {
		t.Fatalf("plot %+v", res.Plot)
	}
	chs, _ := s.ListChanges(store.ChangeQuery{})
	if len(chs) != 1 {
		t.Fatalf("create should be one change, got %d", len(chs))
	}
}

func TestSessionRecords(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Loam")
	rec := store.SessionRecord{SessionID: "abc", PlotID: p.ID, StartFolder: "/r/a"}
	for range 2 { // a second add of the same ID is safe
		if err := s.AddSession(rec); err != nil {
			t.Fatal(err)
		}
	}
	got, err := s.GetSession("abc")
	if err != nil || got.PlotID != p.ID || got.StartFolder != "/r/a" || got.CreatedAt.IsZero() {
		t.Fatalf("got %+v %v", got, err)
	}
	if l, _ := s.ListSessions(p.ID); len(l) != 1 {
		t.Fatalf("list %v", l)
	}
	if ok, _ := s.IsSeeded("abc"); !ok {
		t.Fatal("abc should be seeded")
	}
	if ok, _ := s.IsSeeded("other"); ok {
		t.Fatal("other should not be seeded")
	}
	if a, err := s.SessionActor("abc"); err != nil || !a.LoamStarted || a.Kind != store.ActorSession {
		t.Fatalf("actor %+v %v", a, err)
	}
	if a, err := s.SessionActor("other"); err != nil || a.LoamStarted {
		t.Fatalf("actor %+v %v", a, err)
	}
	other := newPlot(t, s, "Other")
	if err := s.AddSession(store.SessionRecord{SessionID: "abc", PlotID: other.ID}); !errors.Is(err, store.ErrDuplicate) {
		t.Fatalf("reused ID: %v", err)
	}
	if err := s.AddSession(store.SessionRecord{SessionID: "x", PlotID: "nope"}); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("got %v", err)
	}
	if _, err := s.GetSession("zzz"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("got %v", err)
	}
}

func TestPIDSessionRecord(t *testing.T) {
	s := openStore(t)
	if _, ok, _ := s.SessionForPID(42); ok {
		t.Fatal("unexpected record")
	}
	if err := s.SetPIDSession(42, "one"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetPIDSession(42, "two"); err != nil {
		t.Fatal(err)
	}
	if id, ok, err := s.SessionForPID(42); err != nil || !ok || id != "two" {
		t.Fatalf("got %q %v %v", id, ok, err)
	}
}

func rawDB(t *testing.T, home string) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(home, "loam.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func TestSchemaVersionIsRecordedAndReopenIsSafe(t *testing.T) {
	home := testutil.Home(t)
	s, err := store.Open(home)
	if err != nil {
		t.Fatal(err)
	}
	p := newPlot(t, s, "Loam")
	s.Close()
	var v int
	if err := rawDB(t, home).QueryRow(`SELECT version FROM schema_version`).Scan(&v); err != nil || v != store.SchemaVersion {
		t.Fatalf("version %d, err %v", v, err)
	}
	s, err = store.Open(home)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.GetPlot(p.ID); err != nil {
		t.Fatal(err)
	}
}

func TestOlderBinaryRefusesToWrite(t *testing.T) {
	home := testutil.Home(t)
	s, err := store.Open(home)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	p := newPlot(t, s, "Loam")
	// A newer binary migrates the database past this binary's schema.
	if _, err := rawDB(t, home).Exec(`UPDATE schema_version SET version = ?`, store.SchemaVersion+1); err != nil {
		t.Fatal(err)
	}
	edit := []store.Edit{{Op: store.OpSet, Item: "what", Value: "x"}}
	if _, err := s.Apply(store.Change{PlotID: p.ID, Actor: cli, Edits: edit}); !errors.Is(err, store.ErrSchemaNewer) {
		t.Fatalf("Apply: %v", err)
	}
	if _, err := s.CreatePlot(store.PlotInput{Name: "n"}, cli); !errors.Is(err, store.ErrSchemaNewer) {
		t.Fatalf("CreatePlot: %v", err)
	}
	if err := s.AddSession(store.SessionRecord{SessionID: "a", PlotID: p.ID}); !errors.Is(err, store.ErrSchemaNewer) {
		t.Fatalf("AddSession: %v", err)
	}
	// Open still works, and reads still work.
	s2, err := store.Open(home)
	if err != nil {
		t.Fatalf("Open on a newer store: %v", err)
	}
	defer s2.Close()
	if got, err := s2.GetPlot(p.ID); err != nil || got.What != p.What {
		t.Fatalf("read: %+v %v", got, err)
	}
}

// Two processes write to one store at the same time. No write may fail or get lost.
func TestConcurrentWritersFromTwoProcesses(t *testing.T) {
	home := testutil.Home(t)
	s, err := store.Open(home)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	p := newPlot(t, s, "Loam")

	const perProc = 25
	var cmds []*exec.Cmd
	var outs []*bytes.Buffer
	for i := range 2 {
		cmd := exec.Command(os.Args[0], "-test.run=^TestHelperWriter$")
		cmd.Env = append(os.Environ(), "LOAM_STORE_HELPER=1", "LOAM_HOME="+home, "HELPER_PLOT="+p.ID, "HELPER_NAME="+string(rune('a'+i)), fmt.Sprintf("HELPER_N=%d", perProc))
		out := &bytes.Buffer{}
		cmd.Stdout, cmd.Stderr = out, out
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		cmds, outs = append(cmds, cmd), append(outs, out)
	}
	for i, cmd := range cmds {
		if err := cmd.Wait(); err != nil {
			t.Fatalf("writer %d failed: %v\n%s", i, err, outs[i])
		}
	}
	got, err := s.GetPlot(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Links) != 2*perProc {
		t.Fatalf("got %d links, want %d", len(got.Links), 2*perProc)
	}
	chs, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID})
	if len(chs) != 1+2*perProc {
		t.Fatalf("got %d changes", len(chs))
	}
}

// TestHelperWriter is the body of one writer process. It skips in a normal run.
func TestHelperWriter(t *testing.T) {
	if os.Getenv("LOAM_STORE_HELPER") != "1" {
		t.Skip("helper process only")
	}
	s, err := store.OpenHome()
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	n, _ := strconv.Atoi(os.Getenv("HELPER_N"))
	for i := range n {
		_, err := s.Apply(store.Change{PlotID: os.Getenv("HELPER_PLOT"), Actor: cli, Edits: []store.Edit{
			{Op: store.OpAddLink, Label: store.S(fmt.Sprintf("%s%d", os.Getenv("HELPER_NAME"), i)), Target: store.S("t")},
		}})
		if err != nil {
			t.Fatal(err)
		}
	}
}

// Ticket 78: a link added with no label takes one from its target, and the change records it.
func TestAddLinkWithNoLabelNamesItFromTheTarget(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Loam")
	for _, label := range []*string{nil, store.S(""), store.S("  ")} {
		res := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpAddLink, Label: label,
			Target: store.S("https://github.com/GregorMcC/loam/issues/12")}}})
		got := res.Plot.Links[len(res.Plot.Links)-1]
		if got.Label != "loam#12" {
			t.Fatalf("label %q", got.Label)
		}
	}
	cs, err := s.ListChanges(store.ChangeQuery{PlotID: p.ID})
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range cs[len(cs)-1].Entries {
		if e.Field == "label" && e.New != nil && *e.New == "loam#12" {
			return
		}
	}
	t.Fatalf("change does not record the label: %+v", cs[len(cs)-1].Entries)
}
