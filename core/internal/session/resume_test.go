package session_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

const otherID = "aaaaaaaa-2222-4333-8444-555555555555"

func TestResumeArgsAndEnv(t *testing.T) {
	e := setup(t)
	main, other := t.TempDir(), t.TempDir()
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: main}}})
	if out, err := e.run(t, "start", p.ID, "--session-id", fixedID); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	os.Remove(os.Getenv("LOAM_FAKE_CLAUDE_OUT"))
	// The plot changes after the start: resume must use the current plot.
	if _, err := e.store.Apply(store.Change{PlotID: p.ID, Actor: store.Actor{Kind: store.ActorCLI},
		Edits: []store.Edit{{Op: store.OpAddRepo, Path: store.S(other)}, {Op: store.OpSet, Item: "what", Value: "new what"}}}); err != nil {
		t.Fatal(err)
	}
	if out, err := e.run(t, "resume", fixedID); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	if realpath(t, inv.Cwd) != realpath(t, main) {
		t.Errorf("cwd %q, want %q", inv.Cwd, main)
	}
	if got := argValues(inv.Args, "--resume"); !slices.Equal(got, []string{fixedID}) {
		t.Errorf("--resume %v", got)
	}
	if got := argValues(inv.Args, "--session-id"); len(got) != 0 {
		t.Errorf("--session-id %v on resume", got)
	}
	want := []string{filepath.Join(e.home, "plots", p.ID), other}
	if got := argValues(inv.Args, "--add-dir"); !slices.Equal(got, want) {
		t.Errorf("--add-dir %v, want %v", got, want)
	}
	if got := argValues(inv.Args, "--settings"); len(got) != 1 || !strings.HasSuffix(got[0], fixedID+".json") {
		t.Errorf("--settings %v", got)
	}
	if inv.Env["LOAM_PLOT"] != p.ID || inv.Env["CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"] != "1" {
		t.Errorf("env %v", inv.Env)
	}
	if _, ok := inv.Env["CLAUDE_PID"]; ok {
		t.Error("CLAUDE_PID leaked")
	}
	b, err := os.ReadFile(seed.Path(e.store, p.ID))
	if err != nil || !strings.Contains(string(b), "new what") {
		t.Errorf("seed not rewritten: %v", err)
	}
	if recs, _ := e.store.ListSessions(p.ID); len(recs) != 1 {
		t.Errorf("resume added a record: %v", recs)
	}
}

func TestResumeMissingStartFolderFails(t *testing.T) {
	e := setup(t)
	gone := filepath.Join(t.TempDir(), "gone")
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	if err := e.store.AddSession(store.SessionRecord{SessionID: fixedID, PlotID: p.ID, StartFolder: gone}); err != nil {
		t.Fatal(err)
	}
	out, err := e.run(t, "resume", fixedID)
	if err == nil || !strings.Contains(out, gone) {
		t.Fatalf("want an error that names the folder, got %v: %s", err, out)
	}
	if _, err := os.Stat(os.Getenv("LOAM_FAKE_CLAUDE_OUT")); err == nil {
		t.Error("claude started")
	}
}

func TestResumeUnknownSessionFails(t *testing.T) {
	e := setup(t)
	if out, err := e.run(t, "resume", fixedID); err == nil {
		t.Fatalf("want an error: %s", out)
	}
}

func TestSessionsListsNewestFirst(t *testing.T) {
	e := setup(t)
	a := e.plot(t, store.PlotInput{Name: "Alpha"})
	b := e.plot(t, store.PlotInput{Name: "Beta"})
	for _, r := range []store.SessionRecord{
		{SessionID: fixedID, PlotID: a.ID, StartFolder: "/x"},
		{SessionID: otherID, PlotID: b.ID, StartFolder: "/y"},
	} {
		if err := e.store.AddSession(r); err != nil {
			t.Fatal(err)
		}
	}
	out, err := e.run(t, "sessions", "--json")
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	var all []store.SessionRecord
	if err := json.Unmarshal([]byte(out), &all); err != nil {
		t.Fatalf("%q: %v", out, err)
	}
	if len(all) != 2 || all[0].SessionID != otherID || all[1].SessionID != fixedID {
		t.Errorf("got %+v", all)
	}
	out, err = e.run(t, "sessions", "Alpha", "--json")
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	all = nil
	if err := json.Unmarshal([]byte(out), &all); err != nil || len(all) != 1 || all[0].SessionID != fixedID {
		t.Errorf("got %+v %v", all, err)
	}
	if out, err := e.run(t, "sessions"); err != nil || !strings.Contains(out, otherID) {
		t.Errorf("text output %q %v", out, err)
	}
}

func TestHookClearAddsRecordForSeededSession(t *testing.T) {
	e := setup(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	if err := e.store.AddSession(store.SessionRecord{SessionID: "s-old", PlotID: p.ID, StartFolder: "/x"}); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{"CLAUDE_PID": "4242", "LOAM_PLOT": p.ID}
	runHook(t, `{"session_id":"s-old","source":"startup","cwd":"/x"}`, env)
	runHook(t, `{"session_id":"s-new","source":"clear","cwd":"/work/here"}`, env)
	rec, err := e.store.GetSession("s-new")
	if err != nil || rec.PlotID != p.ID || rec.StartFolder != "/work/here" {
		t.Fatalf("record %+v, %v", rec, err)
	}
	if a, _ := e.store.SessionActor("s-new"); !a.LoamStarted {
		t.Error("loam_started is false after clear")
	}
	// A second change chains from the first new ID.
	runHook(t, `{"session_id":"s-new2","source":"resume","cwd":"/work/here"}`, env)
	if ok, _ := e.store.IsSeeded("s-new2"); !ok {
		t.Error("no record after a second change")
	}
}

func TestHookClearIgnoresUnseededSession(t *testing.T) {
	e := setup(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	env := map[string]string{"CLAUDE_PID": "4242", "LOAM_PLOT": p.ID}
	// The earlier ID has no record, so this is not a Loam session.
	runHook(t, `{"session_id":"plain","source":"startup","cwd":"/x"}`, env)
	runHook(t, `{"session_id":"plain2","source":"clear","cwd":"/x"}`, env)
	if ok, _ := e.store.IsSeeded("plain2"); ok {
		t.Error("record for an unseeded session")
	}
	runHook(t, `{"session_id":"lone","source":"clear","cwd":"/x"}`, map[string]string{"CLAUDE_PID": "8", "LOAM_PLOT": p.ID})
	if ok, _ := e.store.IsSeeded("lone"); ok {
		t.Error("record with no earlier session")
	}
}

func TestHookStartupAddsNoRecord(t *testing.T) {
	e := setup(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	e.store.AddSession(store.SessionRecord{SessionID: "s-old", PlotID: p.ID, StartFolder: "/x"})
	env := map[string]string{"CLAUDE_PID": "4242", "LOAM_PLOT": p.ID}
	runHook(t, `{"session_id":"s-old","source":"startup"}`, env)
	runHook(t, `{"session_id":"s-other","source":"startup"}`, env)
	if ok, _ := e.store.IsSeeded("s-other"); ok {
		t.Error("startup added a record")
	}
}

func TestHookResumeOfKnownSessionKeepsRecord(t *testing.T) {
	e := setup(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	e.store.AddSession(store.SessionRecord{SessionID: "s1", PlotID: p.ID, StartFolder: "/orig"})
	runHook(t, `{"session_id":"s1","source":"resume","cwd":"/elsewhere"}`, map[string]string{"CLAUDE_PID": "5", "LOAM_PLOT": p.ID})
	if rec, _ := e.store.GetSession("s1"); rec.StartFolder != "/orig" {
		t.Errorf("record changed: %+v", rec)
	}
}
