package run

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
)

// runWithTemp returns a store and a run in state, with a private folder.
func runWithTemp(t *testing.T, state store.RunState) (*store.Store, store.Run) {
	t.Helper()
	s, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	res, err := s.CreatePlot(store.PlotInput{Name: "Temp"}, store.Actor{Kind: store.ActorCLI})
	if err != nil {
		t.Fatal(err)
	}
	r, err := s.AddRun(store.Run{PlotID: res.Plot.ID, Title: "Temp", Folder: t.TempDir(), State: state})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(session.RunTemp(s, r.ID), 0o700); err != nil {
		t.Fatal(err)
	}
	return s, r
}

// TAS-216: the SessionStart hook gives Bash the xcrun cache in the private
// folder of the run, through CLAUDE_ENV_FILE. It appends, so the lines of
// other hooks stay. Claude Code gives the file to no process outside the
// sandbox.
func TestSessionStartGivesBashThePrivateXcrunCache(t *testing.T) {
	s, r := runWithTemp(t, store.RunStarting)
	file := filepath.Join(t.TempDir(), "env.sh")
	if err := os.WriteFile(file, []byte("export A=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLAUDE_ENV_FILE", file)
	in := `{"hook_event_name":"SessionStart","session_id":"11111111-2222-4333-8444-555555555555","source":"resume"}`
	if code := Hook(s, r.ID, strings.NewReader(in), new(strings.Builder), new(strings.Builder)); code != 0 {
		t.Fatalf("exit %d", code)
	}
	b, err := os.ReadFile(file)
	if want := "export A=1\n" + session.RunBashEnv(s, r.ID); err != nil || string(b) != want {
		t.Errorf("env file = %q, %v, want %q", b, err, want)
	}
	// A run that Loam does not know writes nothing.
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	Hook(s, "gone", strings.NewReader(in), new(strings.Builder), new(strings.Builder))
	if b, err := os.ReadFile(file); err != nil || len(b) != 0 {
		t.Errorf("env file for a gone run = %q, %v, want it empty", b, err)
	}
}

// TAS-216: the private folder of a run goes when the run ends: when you
// cancel it and when it lands.
func TestARunThatEndsRemovesItsPrivateFolder(t *testing.T) {
	s, r := runWithTemp(t, store.RunShaping)
	if _, _, err := Cancel(context.Background(), s, r.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(session.RunTemp(s, r.ID)); !os.IsNotExist(err) {
		t.Errorf("the private folder after Cancel: %v, want none", err)
	}
	s, r = runWithTemp(t, store.RunReady)
	if _, moved, _, err := landRun(context.Background(), s, r, "Merged", false); err != nil || !moved {
		t.Fatalf("landRun: moved %v, %v", moved, err)
	}
	if _, err := os.Lstat(session.RunTemp(s, r.ID)); !os.IsNotExist(err) {
		t.Errorf("the private folder after land: %v, want none", err)
	}
}
