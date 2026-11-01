package session_test

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/seed"
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
