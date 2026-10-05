package cli

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// fakeUserHome points HOME at a temp folder, so ~/.Trash and ~/.claude are
// the test's own. It clears CLAUDE_CONFIG_DIR.
func fakeUserHome(t *testing.T) string {
	t.Helper()
	h := t.TempDir()
	t.Setenv("HOME", h)
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	return h
}

func listIDs(t *testing.T, args ...string) []string {
	t.Helper()
	out, _, err := lrRun(t, "", append([]string{"list", "--json"}, args...)...)
	if err != nil {
		t.Fatal(err)
	}
	var rows []struct {
		ID       string `json:"id"`
		Archived bool   `json:"archived"`
	}
	if err := json.Unmarshal([]byte(out), &rows); err != nil {
		t.Fatal(err)
	}
	ids := []string{}
	for _, r := range rows {
		ids = append(ids, r.ID)
	}
	return ids
}

func TestArchiveUnarchiveAndListArchived(t *testing.T) {
	s, a := linkRepoEnv(t, store.PlotInput{Name: "Alpha"})
	res, err := s.CreatePlot(store.PlotInput{Name: "Beta"}, store.Actor{Kind: store.ActorCLI})
	if err != nil {
		t.Fatal(err)
	}
	b := res.Plot

	out, _, err := lrRun(t, "", "archive", "Alpha")
	if err != nil || !strings.Contains(out, "Archived Alpha") {
		t.Fatalf("%q %v", out, err)
	}
	if got := listIDs(t); len(got) != 1 || got[0] != b.ID {
		t.Fatalf("default list %v", got)
	}
	if got := listIDs(t, "--archived"); len(got) != 1 || got[0] != a.ID {
		t.Fatalf("archived list %v", got)
	}
	// Text output of the archived list.
	if text, _, _ := lrRun(t, "", "list", "--archived"); !strings.Contains(text, "Alpha") || strings.Contains(text, "Beta") {
		t.Fatalf("%q", text)
	}
	// Reads and edits still work, and the plot object has the flag.
	out, _, err = lrRun(t, "", "show", a.ID, "--json")
	var shown store.Plot
	if err != nil || json.Unmarshal([]byte(out), &shown) != nil || !shown.Archived {
		t.Fatalf("%q %v", out, err)
	}
	if _, _, err := lrRun(t, "", "set", a.ID, "what", "still editable"); err != nil {
		t.Fatal(err)
	}
	// The flag is not in the change log.
	changes, _ := s.ListChanges(store.ChangeQuery{PlotID: a.ID})
	for _, c := range changes {
		for _, e := range c.Entries {
			if strings.Contains(e.Item, "archiv") {
				t.Fatalf("archive wrote a change entry: %+v", e)
			}
		}
	}

	out, _, err = lrRun(t, "", "unarchive", "Alpha", "--json")
	var back store.Plot
	if err != nil || json.Unmarshal([]byte(out), &back) != nil || back.Archived || back.ID != a.ID {
		t.Fatalf("%q %v", out, err)
	}
	if got := listIDs(t); len(got) != 2 || got[0] != a.ID {
		t.Fatalf("unarchive lost the place: %v", got)
	}
	if got := listIDs(t, "--archived"); len(got) != 0 {
		t.Fatalf("%v", got)
	}
	if text, _, err := lrRun(t, "", "unarchive", "Alpha"); err != nil || !strings.Contains(text, "Unarchived Alpha") {
		t.Fatalf("%q %v", text, err)
	}
	// An unknown plot gives the unknown plot error.
	if _, _, err := lrRun(t, "", "archive", "nosuch"); !errors.Is(err, ErrUnknownPlot) {
		t.Fatalf("%v", err)
	}
}

func archivedPlot(t *testing.T, in store.PlotInput) (*store.Store, store.Plot) {
	t.Helper()
	s, p := linkRepoEnv(t, in)
	if _, _, err := lrRun(t, "", "archive", p.ID); err != nil {
		t.Fatal(err)
	}
	return s, p
}

func TestDeleteRefusesAPlotThatIsNotArchived(t *testing.T) {
	fakeUserHome(t)
	s, p := linkRepoEnv(t, store.PlotInput{Name: "Alpha"})
	_, _, err := lrRun(t, "", "delete", p.ID)
	if !errors.Is(err, store.ErrNotArchived) || !strings.Contains(err.Error(), "loam archive") {
		t.Fatalf("%v", err)
	}
	if _, err := s.GetPlot(p.ID); err != nil {
		t.Fatal("the plot is gone")
	}
	if _, err := os.Stat(s.PlotDir(p.ID)); err != nil {
		t.Fatal("the plot folder is gone")
	}
	if got := classify(err).ExitCode; got != ExitError {
		t.Fatalf("exit code %d", got)
	}
}

func TestDeleteRefusesAPlotWithWorktrees(t *testing.T) {
	fakeUserHome(t)
	s, p := archivedPlot(t, store.PlotInput{Name: "Alpha"})
	if _, err := s.AddWorktree(store.Worktree{PlotID: p.ID, Repo: "/r", Name: "x", Branch: "x", Path: "/w/x"}); err != nil {
		t.Fatal(err)
	}
	_, _, err := lrRun(t, "", "delete", p.ID)
	if !errors.Is(err, store.ErrHasWorktrees) || !strings.Contains(err.Error(), "worktree rm") {
		t.Fatalf("%v", err)
	}
	if _, err := s.GetPlot(p.ID); err != nil {
		t.Fatal("the plot is gone")
	}
	if _, err := os.Stat(s.PlotDir(p.ID)); err != nil {
		t.Fatal("the plot folder is gone")
	}
	// After the worktree record goes, the delete works.
	ws, _ := s.ListWorktrees(p.ID)
	if err := s.RemoveWorktree(ws[0].ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := lrRun(t, "", "delete", p.ID); err != nil {
		t.Fatal(err)
	}
}

func TestDeleteMovesFolderToTrashAndPrintsClaudeFiles(t *testing.T) {
	home := fakeUserHome(t)
	start := filepath.Join(t.TempDir(), "my.repo")
	gone := filepath.Join(t.TempDir(), "other")
	s, p := archivedPlot(t, store.PlotInput{Name: "Alpha", Links: []store.LinkInput{{Label: "L", Target: "https://example.com"}}})
	if err := os.WriteFile(filepath.Join(s.PlotDir(p.ID), "note.md"), []byte("keep me"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Claude Code names its folder after the start folder: "/" and "." become "-".
	claudeName := func(dir string) string {
		return filepath.Join(home, ".claude", "projects", claudeProjectName(dir))
	}
	if err := os.MkdirAll(claudeName(start), 0o755); err != nil {
		t.Fatal(err)
	}
	for i, f := range []string{start, start, gone} { // two sessions share a folder, one folder has no Claude files
		id := []string{"11111111-2222-4333-8444-555555555555", "22222222-2222-4333-8444-555555555555", "33333333-2222-4333-8444-555555555555"}[i]
		if err := s.AddSession(store.SessionRecord{SessionID: id, PlotID: p.ID, StartFolder: f}); err != nil {
			t.Fatal(err)
		}
	}
	settings := filepath.Join(s.Home(), "sessions", "11111111-2222-4333-8444-555555555555.json")
	os.MkdirAll(filepath.Dir(settings), 0o755)
	os.WriteFile(settings, []byte("{}"), 0o644)

	out, _, err := lrRun(t, "", "delete", "Alpha")
	if err != nil {
		t.Fatal(err)
	}
	trashed := filepath.Join(home, ".Trash", p.ID)
	if b, err := os.ReadFile(filepath.Join(trashed, "note.md")); err != nil || string(b) != "keep me" {
		t.Fatalf("the folder is not in the Trash: %v", err)
	}
	if _, err := os.Stat(s.PlotDir(p.ID)); !os.IsNotExist(err) {
		t.Fatal("the plot folder is still in place")
	}
	if _, err := os.Stat(settings); !os.IsNotExist(err) {
		t.Fatal("the session settings file is still there")
	}
	if !strings.Contains(out, trashed) || strings.Count(out, claudeName(start)) != 1 || strings.Contains(out, claudeName(gone)) {
		t.Fatalf("output:\n%s", out)
	}
	if _, err := s.GetPlot(p.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("%v", err)
	}
	if rs, _ := s.ListSessions(""); len(rs) != 0 {
		t.Fatalf("%v", rs)
	}
	// Loam never removes the files of Claude Code.
	if _, err := os.Stat(claudeName(start)); err != nil {
		t.Fatal("the Claude Code folder is gone")
	}
}

func TestDeleteJSONAndTrashNameTaken(t *testing.T) {
	home := fakeUserHome(t)
	s, p := archivedPlot(t, store.PlotInput{Name: "Alpha"})
	if err := os.MkdirAll(filepath.Join(home, ".Trash", p.ID), 0o755); err != nil { // the name is taken
		t.Fatal(err)
	}
	out, _, err := lrRun(t, "", "delete", p.ID, "--json")
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Plot, Name, Trash string
		ClaudeFiles       []string `json:"claude_files"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if got.Plot != p.ID || got.Name != "Alpha" || got.Trash != filepath.Join(home, ".Trash", p.ID+" 2") || got.ClaudeFiles == nil || len(got.ClaudeFiles) != 0 {
		t.Fatalf("%+v", got)
	}
	if _, err := os.Stat(got.Trash); err != nil {
		t.Fatal(err)
	}
	if _, err := s.GetPlot(p.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatal("the plot is still there")
	}
}

func TestDeleteHonoursClaudeConfigDir(t *testing.T) {
	fakeUserHome(t)
	cfg := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	start := "/some/start"
	s, p := archivedPlot(t, store.PlotInput{Name: "Alpha"})
	if err := s.AddSession(store.SessionRecord{SessionID: "11111111-2222-4333-8444-555555555555", PlotID: p.ID, StartFolder: start}); err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(cfg, "projects", "-some-start")
	if err := os.MkdirAll(want, 0o755); err != nil {
		t.Fatal(err)
	}
	out, _, err := lrRun(t, "", "delete", p.ID)
	if err != nil || !strings.Contains(out, want) {
		t.Fatalf("%v\n%s", err, out)
	}
}

func TestClaudeProjectName(t *testing.T) {
	if got := claudeProjectName("/Users/me/My Repo/my_app.v2"); got != "-Users-me-My-Repo-my-app-v2" {
		t.Fatalf("got %q", got)
	}
}
