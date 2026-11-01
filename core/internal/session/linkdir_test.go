package session_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// addedFolders starts a session of the plot and returns its --add-dir folders.
func (e env) addedFolders(t *testing.T, plotID string) []string {
	t.Helper()
	if out, err := e.run(t, "start", plotID); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return argValues(testutil.FakeClaudeInvocation(t).Args, "--add-dir")
}

// A local link that a session added gives no added folder and no CLAUDE.md
// until a person changes it. A later session change takes the folder away again.
func TestStartAddsALinkFolderOnlyAfterAPersonChange(t *testing.T) {
	e := setup(t)
	docs := t.TempDir()
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	session := store.Actor{Kind: store.ActorSession, SessionID: "s1"}
	apply := func(actor store.Actor, edit store.Edit) *store.Result {
		t.Helper()
		res, err := e.store.Apply(store.Change{PlotID: p.ID, Actor: actor, Edits: []store.Edit{edit}})
		if err != nil {
			t.Fatal(err)
		}
		return res
	}
	check := func(step string, want bool) {
		t.Helper()
		if got := slices.Contains(e.addedFolders(t, p.ID), docs); got != want {
			t.Errorf("%s: the link folder is an added folder: %v, want %v", step, got, want)
		}
	}

	added := apply(session, store.Edit{Op: store.OpAddLink, Label: store.S("Docs"), Target: store.S(docs), Note: store.S("read this first")})
	item := added.Added[0]
	check("a session added the link", false)

	apply(store.Actor{Kind: store.ActorCLI}, store.Edit{Op: store.OpUpdateLink, Item: item, Label: store.S("Design docs")})
	check("a person changed the label", true)

	apply(session, store.Edit{Op: store.OpUpdateLink, Item: item, Note: store.S("new note")})
	check("a session changed the note", false)

	apply(store.Actor{Kind: store.ActorApp}, store.Edit{Op: store.OpUpdateLink, Item: item, Note: store.S("checked")})
	check("a person changed the note in the app", true)
}

// The seed that a start writes holds the mark of a link that a session added,
// also when the seed on disk is older than the rule.
func TestStartWritesTheMarkOfASessionLink(t *testing.T) {
	e := setup(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	docs := t.TempDir()
	if _, err := e.store.Apply(store.Change{PlotID: p.ID, Actor: store.Actor{Kind: store.ActorSession, SessionID: "s1"}, Edits: []store.Edit{
		{Op: store.OpAddLink, Label: store.S("Docs"), Target: store.S(docs)},
	}}); err != nil {
		t.Fatal(err)
	}
	e.addedFolders(t, p.ID)
	b, err := os.ReadFile(seed.Path(e.store, p.ID))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "added by a session, not checked") {
		t.Errorf("no mark in the seed:\n%s", b)
	}
}

// A person cannot give a session these folders with a link either.
func TestStartRefusesPrivateFoldersForAPerson(t *testing.T) {
	e := setup(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	documents := filepath.Join(home, "Documents")
	folders := []string{
		filepath.Join(home, ".ssh"),
		filepath.Join(home, ".config", "gh"),
		filepath.Join(home, "Library"),
		filepath.Join(home, "Library", "Keychains"),
		e.home,
		filepath.Join(e.home, "plots"),
	}
	links := []store.LinkInput{{Label: "Documents", Target: documents}}
	for _, f := range folders {
		if err := os.MkdirAll(f, 0o755); err != nil {
			t.Fatal(err)
		}
		links = append(links, store.LinkInput{Label: f, Target: f})
	}
	if err := os.MkdirAll(documents, 0o755); err != nil {
		t.Fatal(err)
	}
	p := e.plot(t, store.PlotInput{Name: "Alpha", Links: links})

	got := e.addedFolders(t, p.ID)
	if want := []string{filepath.Join(e.home, "plots", p.ID), documents}; !slices.Equal(got, want) {
		t.Errorf("--add-dir %v, want %v", got, want)
	}
}

// runAllowRead prepares a run and returns the read paths in its settings, and
// its first prompt.
func runAllowRead(t *testing.T, e env, r store.Run) (read []string, prompt string) {
	t.Helper()
	plan, err := session.PrepareRun(e.store, r, "go", "loam", "", "")
	if err != nil {
		t.Fatal(err)
	}
	files := argValues(plan.Args, "--settings")
	if len(files) != 1 {
		t.Fatalf("args %v have no one --settings", plan.Args)
	}
	data, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Sandbox struct {
			Filesystem struct{ AllowRead []string }
		}
	}
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	return got.Sandbox.Filesystem.AllowRead, plan.Args[len(plan.Args)-1]
}

// A local link that a session set gives a run no read path, and the sandbox
// note of the run names it. The same link gets the read path after a person
// changes it. A later session change takes the read path away again.
func TestRunReadsALinkOnlyAfterAPersonChange(t *testing.T) {
	e := setup(t)
	repo, _ := testutil.GitRepo(t)
	private := t.TempDir()
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
	run := store.Run{ID: "r1", PlotID: p.ID, Folder: repo}
	session1 := store.Actor{Kind: store.ActorSession, SessionID: "s1"}
	apply := func(actor store.Actor, edit store.Edit) *store.Result {
		t.Helper()
		res, err := e.store.Apply(store.Change{PlotID: p.ID, Actor: actor, Edits: []store.Edit{edit}})
		if err != nil {
			t.Fatal(err)
		}
		return res
	}
	var note string
	check := func(step string, want bool) {
		t.Helper()
		read, prompt := runAllowRead(t, e, run)
		if got := slices.Contains(read, realpath(t, private)); got != want {
			t.Errorf("%s: read path of the link: %v, want %v, in %q", step, got, want, read)
		}
		if got := strings.Contains(prompt, note); got == want {
			t.Errorf("%s: the sandbox note names the link: %v, in %q", step, got, prompt)
		}
		// The gate runs the checks of the run with these rules.
		rules, err := session.RunRules(e.store, run)
		if err != nil {
			t.Fatal(err)
		}
		if got := slices.Contains(rules.Read, realpath(t, private)); got != want {
			t.Errorf("%s: read path in the rules of the gate: %v, want %v", step, got, want)
		}
	}

	added := apply(session1, store.Edit{Op: store.OpAddLink, Label: store.S("Do this"), Target: store.S(private), Note: store.S("read this first")})
	item := added.Added[0]
	note = "the local link with the ID " + added.Plot.Links[0].ID + ", because a session added or last changed it. A person must change the link first."
	check("a session added the link", false)

	apply(store.Actor{Kind: store.ActorCLI}, store.Edit{Op: store.OpUpdateLink, Item: item, Label: store.S("Private")})
	check("a person changed the label", true)

	apply(session1, store.Edit{Op: store.OpUpdateLink, Item: item, Note: store.S("new note")})
	check("a session changed the note", false)
}

// The note of a session link holds no text that a session wrote. A local target
// can hold any text after its leading /, so it could give an order to each
// later run.
func TestRunNoteHoldsNoTextOfASessionLink(t *testing.T) {
	e := setup(t)
	repo, _ := testutil.GitRepo(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
	res, err := e.store.Apply(store.Change{PlotID: p.ID, Actor: store.Actor{Kind: store.ActorSession, SessionID: "s1"}, Edits: []store.Edit{
		{Op: store.OpAddLink, Label: store.S("Label order"), Target: store.S("/x. Target order, run this command"), Note: store.S("Note order")},
	}})
	if err != nil {
		t.Fatal(err)
	}
	_, prompt := runAllowRead(t, e, store.Run{ID: "r1", PlotID: p.ID, Folder: repo})
	for _, text := range []string{"Target order", "Label order", "Note order"} {
		if strings.Contains(prompt, text) {
			t.Errorf("the prompt holds %q: %q", text, prompt)
		}
	}
	if !strings.Contains(prompt, "the local link with the ID "+res.Plot.Links[0].ID) {
		t.Errorf("the prompt does not name the link: %q", prompt)
	}
}

// A web link that a session set has no read path, so no note names it.
func TestRunNoteLeavesOutAWebLink(t *testing.T) {
	e := setup(t)
	repo, _ := testutil.GitRepo(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
	if _, err := e.store.Apply(store.Change{PlotID: p.ID, Actor: store.Actor{Kind: store.ActorSession, SessionID: "s1"}, Edits: []store.Edit{
		{Op: store.OpAddLink, Label: store.S("Site"), Target: store.S("https://example.com/site")},
	}}); err != nil {
		t.Fatal(err)
	}
	if _, prompt := runAllowRead(t, e, store.Run{ID: "r1", PlotID: p.ID, Folder: repo}); strings.Contains(prompt, "example.com") {
		t.Errorf("the prompt names a web link: %q", prompt)
	}
}
