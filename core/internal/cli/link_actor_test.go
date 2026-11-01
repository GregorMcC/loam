package cli

import (
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func lastActor(t *testing.T, s *store.Store, plotID string) store.Actor {
	t.Helper()
	chs, err := s.ListChanges(store.ChangeQuery{PlotID: plotID, Newest: true, Limit: 1})
	if err != nil || len(chs) != 1 {
		t.Fatalf("changes %v: %+v", err, chs)
	}
	return chs[0].Actor
}

// A link command that a Claude Code session started records that session, so
// the link gets no added folder. --actor app does not change this.
func TestLinkCommandInASessionRecordsTheSession(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	t.Setenv("CLAUDECODE", "1")
	t.Setenv("CLAUDE_CODE_SESSION_ID", "s1")

	for _, args := range [][]string{
		{"link", "add", "alpha", "One", "/one"},
		{"link", "add", "alpha", "Two", "/two", "--actor", "app"},
		{"link", "edit", "alpha", "One", "--note", "new"},
		{"link", "edit", "alpha", "Two", "--note", "new", "--actor", "app"},
	} {
		if _, _, err := lrRun(t, "", args...); err != nil {
			t.Fatalf("%v: %v", args, err)
		}
		if a := lastActor(t, s, p.ID); a.Kind != store.ActorSession || a.SessionID != "s1" {
			t.Errorf("%v: actor %+v", args, a)
		}
	}
	for _, l := range lrPlot(t, s, p.ID).Links {
		if !l.Unchecked {
			t.Errorf("link %s is not unchecked", l.Label)
		}
	}

	t.Setenv("CLAUDE_CODE_SESSION_ID", "")
	if _, _, err := lrRun(t, "", "link", "edit", "alpha", "One", "--note", "again"); err != nil {
		t.Fatal(err)
	}
	if a := lastActor(t, s, p.ID); a.Kind != store.ActorSession || a.SessionID != "" {
		t.Errorf("with no session ID: actor %+v", a)
	}
}

// A session must not confirm its own link with a CLI undo: the undo of a
// removal brings the link back, and the undo is the last change to it.
func TestUndoInASessionRecordsTheSession(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	t.Setenv("CLAUDECODE", "1")
	t.Setenv("CLAUDE_CODE_SESSION_ID", "s1")
	if _, _, err := lrRun(t, "", "link", "add", "alpha", "Keys", "/keys"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := lrRun(t, "", "link", "rm", "alpha", "Keys"); err != nil {
		t.Fatal(err)
	}
	chs, err := s.ListChanges(store.ChangeQuery{PlotID: p.ID, Newest: true, Limit: 1})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := lrRun(t, "", "undo", lrItoa(chs[0].ID), "--json", "--actor", "app"); err != nil {
		t.Fatal(err)
	}
	links := lrPlot(t, s, p.ID).Links
	if len(links) != 1 || !links[0].Unchecked {
		t.Fatalf("links %+v", links)
	}
	if a := lastActor(t, s, p.ID); a.Kind != store.ActorSession {
		t.Errorf("actor %+v", a)
	}
}

// With no CLAUDECODE=1, the CLI is a person, and a change to a link confirms it.
func TestLinkCommandOfAPersonConfirmsASessionLink(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	res, err := s.Apply(store.Change{PlotID: p.ID, Actor: store.Actor{Kind: store.ActorSession, SessionID: "s1"}, Edits: []store.Edit{
		{Op: store.OpAddLink, Label: store.S("Docs"), Target: store.S("/docs"), Note: store.S("note")},
	}})
	if err != nil {
		t.Fatal(err)
	}
	id := res.Plot.Links[0].ID

	// The same values write no change, and the command says so.
	out, _, err := lrRun(t, "", "link", "edit", "alpha", id, "--target", "/docs", "--note", "note")
	if err != nil || !strings.Contains(out, "No change.") {
		t.Fatalf("%v: %s", err, out)
	}
	if !lrPlot(t, s, p.ID).Links[0].Unchecked {
		t.Error("an edit with the same values confirmed the link")
	}

	// A new label keeps the target and the note.
	if _, _, err := lrRun(t, "", "link", "edit", "alpha", id, "--label", "Design docs"); err != nil {
		t.Fatal(err)
	}
	got := lrPlot(t, s, p.ID).Links[0]
	if got.Unchecked || got.Target != "/docs" || got.Note != "note" {
		t.Errorf("after a label edit: %+v", got)
	}
	if a := lastActor(t, s, p.ID); a.Kind != store.ActorCLI {
		t.Errorf("actor %+v", a)
	}

	if _, _, err := lrRun(t, "", "link", "edit", "alpha", id, "--note", "from the app", "--actor", "app"); err != nil {
		t.Fatal(err)
	}
	if a := lastActor(t, s, p.ID); a.Kind != store.ActorApp {
		t.Errorf("--actor app: actor %+v", a)
	}

	// Only the value 1 means a session.
	t.Setenv("CLAUDECODE", "0")
	if _, _, err := lrRun(t, "", "link", "edit", "alpha", id, "--note", "other value"); err != nil {
		t.Fatal(err)
	}
	if a := lastActor(t, s, p.ID); a.Kind != store.ActorCLI {
		t.Errorf("CLAUDECODE=0: actor %+v", a)
	}
}

// A repo add in a session adds the remote of the repo as a link. That link is
// marked as a link that a session added.
func TestRepoAddInASessionMarksTheRemoteLink(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	d := lrRepoDirs(t, 1)
	lrGitRepo(t, d[0], "git@github.com:me/app.git")
	t.Setenv("CLAUDECODE", "1")
	t.Setenv("CLAUDE_CODE_SESSION_ID", "s1")
	if _, _, err := lrRun(t, "", "repo", "add", "alpha", d[0], "--actor", "app"); err != nil {
		t.Fatal(err)
	}
	got := lrPlot(t, s, p.ID)
	if len(got.Links) != 1 || !got.Links[0].Unchecked {
		t.Fatalf("links %+v", got.Links)
	}
	if a := lastActor(t, s, p.ID); a.Kind != store.ActorSession || a.SessionID != "s1" {
		t.Errorf("actor %+v", a)
	}
}

// With no CLAUDECODE=1, a repo add is a person, and its remote link is checked.
func TestRepoAddOfAPersonLeavesTheRemoteLinkChecked(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	d := lrRepoDirs(t, 1)
	lrGitRepo(t, d[0], "git@github.com:me/app.git")
	if _, _, err := lrRun(t, "", "repo", "add", "alpha", d[0]); err != nil {
		t.Fatal(err)
	}
	got := lrPlot(t, s, p.ID)
	if len(got.Links) != 1 || got.Links[0].Unchecked {
		t.Fatalf("links %+v", got.Links)
	}
}

// CLAUDECODE=1 changes only the writes that can set a link.
func TestOtherWritesInASessionKeepTheCLIActor(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	t.Setenv("CLAUDECODE", "1")
	if _, _, err := lrRun(t, "", "set", "alpha", "where-it-stands", "new text"); err != nil {
		t.Fatal(err)
	}
	if a := lastActor(t, s, p.ID); a.Kind != store.ActorCLI {
		t.Errorf("actor %+v", a)
	}
}
