package cli

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"unicode"

	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

const (
	cliLinearIssue = "https://linear.app/example/issue/ENG-482/link-kinds-for-figma"
	cliGitHubIssue = "https://github.com/example/widgets/issues/57"
)

type worktreeOut struct {
	ChangeID int64          `json:"change_id"`
	Plot     string         `json:"plot"`
	Worktree store.Worktree `json:"worktree"`
}

func decodeWorktree(t *testing.T, out string) worktreeOut {
	t.Helper()
	var v worktreeOut
	if err := json.Unmarshal([]byte(out), &v); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return v
}

func TestWorktreeNewWithGoalAndLink(t *testing.T) {
	s, p, repo := wtCLI(t)
	out, _, err := lrRun(t, "", "link", "add", "alpha", "Link kinds for Figma", cliLinearIssue, "--json")
	if err != nil {
		t.Fatal(err)
	}
	var added struct{ Link store.Link }
	json.Unmarshal([]byte(out), &added)

	// A link ID copies the plot link.
	out, _, err = lrRun(t, "", "worktree", "new", "alpha", repo, "eng-482", "--goal", "Link kinds for Figma", "--link", added.Link.ID, "--json")
	if err != nil {
		t.Fatal(err)
	}
	w := decodeWorktree(t, out).Worktree
	want := store.WorktreeLink{Target: cliLinearIssue, Label: "Link kinds for Figma", Key: "ENG-482", LinkID: added.Link.ID}
	if w.Goal != "Link kinds for Figma" || w.Link == nil || *w.Link != want {
		t.Fatalf("%+v %+v", w, w.Link)
	}
	// A URL must be an issue. It stays out of the plot's links.
	text, _, err := lrRun(t, "", "worktree", "new", "alpha", repo, "fix-57", "--link", cliGitHubIssue)
	if err != nil {
		t.Fatal(err)
	}
	// The origin of the repo is not on GitHub, so the key names the repo of
	// the issue. The text, the JSON, and the seed show the same key.
	const key = "example/widgets#57"
	if !strings.Contains(text, "Link: "+key+" widgets#57 ("+cliGitHubIssue+")") {
		t.Fatalf("text %q", text)
	}
	if b, err := os.ReadFile(seed.Path(s, p.ID)); err != nil || !strings.Contains(string(b), "- app-fix-57 ("+key+", from origin/main)\n") {
		t.Fatalf("seed: %v\n%s", err, b)
	}
	out, _, err = lrRun(t, "", "worktree", "list", "alpha", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var listed []worktree.Status
	if err := json.Unmarshal([]byte(out), &listed); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if i := slices.IndexFunc(listed, func(st worktree.Status) bool { return st.Worktree.Name == "fix-57" }); i < 0 ||
		listed[i].Worktree.Link == nil || listed[i].Worktree.Link.Key != key {
		t.Fatalf("list --json: %s", out)
	}
	if links := lrPlot(t, s, p.ID).Links; len(links) != 1 {
		t.Fatalf("links %+v", links)
	}
	for _, bad := range []string{"https://github.com/example/widgets/pull/57", "https://example.com/x"} {
		if _, _, err := lrRun(t, "", "worktree", "new", "alpha", repo, "bad", "--link", bad); !errors.Is(err, store.ErrInvalid) {
			t.Errorf("%s: %v", bad, err)
		}
	}
	// The text output shows the goal.
	text, _, err = lrRun(t, "", "worktree", "new", "alpha", repo, "panel", "--goal", "Native panel spacing")
	if err != nil || !strings.Contains(text, "Goal: Native panel spacing") {
		t.Fatalf("%q %v", text, err)
	}
	// worktree list shows the goal and the link key under each worktree.
	text, _, err = lrRun(t, "", "worktree", "list", "alpha")
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range []string{"    Link kinds for Figma (ENG-482)\n", "    " + key + "\n", "    Native panel spacing\n"} {
		if !strings.Contains(text, line) {
			t.Errorf("list misses %q:\n%s", line, text)
		}
	}
}

// A goal with an escape sequence never reaches the terminal through the text
// output. The JSON keeps the goal as it was given.
func TestWorktreeTextDropsControlCharactersOfTheGoal(t *testing.T) {
	_, _, repo := wtCLI(t)
	// An ESC color sequence, an OSC sequence that sets the terminal title,
	// NUL, 0x1c to 0x1f, and the C1 control CSI (U+009B).
	const goal = "Fix \x1b[31mthe login\x1b[0m form\x00 \x1b]0;owned\x07 now\x1c\x1d\x1e\x1f\u009b"
	const shown = "Fix [31mthe login [0m form ]0;owned now"
	noControl := func(what, text string) {
		t.Helper()
		for _, r := range text {
			if r != '\n' && unicode.IsControl(r) {
				t.Errorf("%s holds the control character %U: %q", what, r, text)
				return
			}
		}
	}
	text, _, err := lrRun(t, "", "worktree", "new", "alpha", repo, "fix-login", "--goal", goal)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(text, "Goal: "+shown+"\n") {
		t.Errorf("new: %q", text)
	}
	noControl("new", text)
	text, _, err = lrRun(t, "", "worktree", "list", "alpha")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(text, "    "+shown+"\n") {
		t.Errorf("list: %q", text)
	}
	noControl("list", text)
	out, _, err := lrRun(t, "", "worktree", "list", "alpha", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var listed []worktree.Status
	if err := json.Unmarshal([]byte(out), &listed); err != nil || len(listed) != 1 || listed[0].Worktree.Goal != goal {
		t.Fatalf("list --json: %v %s", err, out)
	}
}

func TestWorktreeNewLongGoalWarns(t *testing.T) {
	_, _, repo := wtCLI(t)
	_, errOut, err := lrRun(t, "", "worktree", "new", "alpha", repo, "long", "--goal", strings.Repeat("word ", 24), "--json")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(errOut, "The goal has 24 words. The soft limit is 20 words. Shorten it.") {
		t.Fatalf("stderr %q", errOut)
	}
}

func TestWorktreeNewDryRun(t *testing.T) {
	s, p, repo := wtCLI(t)
	dry := func(name string, extra ...string) worktree.CheckResult {
		t.Helper()
		out, errOut, err := lrRun(t, "", append([]string{"worktree", "new", "alpha", repo, name, "--dry-run", "--json"}, extra...)...)
		if err != nil {
			t.Fatalf("%s: %v %s", name, err, errOut)
		}
		var res worktree.CheckResult
		if err := json.Unmarshal([]byte(out), &res); err != nil {
			t.Fatalf("%v: %s", err, out)
		}
		return res
	}
	got := dry("fix-login", "--goal", "Fix the login form", "--link", cliGitHubIssue)
	if !got.ValidName || got.BranchExists || got.DefaultBase != "origin/main" || !slices.Equal(got.Bases, []string{"origin/main", "main"}) {
		t.Fatalf("valid: %+v", got)
	}
	if got := dry("a b"); got.ValidName || got.NameError == "" || strings.Contains(got.NameError, store.ErrInvalid.Error()) {
		t.Fatalf("invalid: %+v", got)
	}
	if got := dry("main"); !got.ValidName || !got.BranchExists {
		t.Fatalf("existing: %+v", got)
	}
	// The New worktree sheet sends its base as you type. For a branch that
	// exists, the dry run reports the branch and does not check the base.
	if got := dry("main", "--base", "origin/main"); !got.ValidName || !got.BranchExists {
		t.Fatalf("existing with a base: %+v", got)
	}
	text, _, err := lrRun(t, "", "worktree", "new", "alpha", repo, "main", "--dry-run", "--base", "origin/main")
	if err != nil || !strings.Contains(text, "The worktree app-main can use the branch main, which exists, so --base does not apply.\n") {
		t.Fatalf("%q %v", text, err)
	}
	// worktree new still refuses the base.
	if _, _, err := lrRun(t, "", "worktree", "new", "alpha", repo, "main", "--base", "origin/main"); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("new with a base for a branch that exists: %v", err)
	}
	if ws, _ := s.ListWorktrees(p.ID); len(ws) != 0 {
		t.Fatalf("a dry run made %+v", ws)
	}
	if _, err := os.Stat(filepath.Join(s.Home(), "worktrees", p.ID, "app-fix-login")); !os.IsNotExist(err) {
		t.Fatalf("folder: %v", err)
	}
	// A bad link fails the dry run as it fails new.
	if _, _, err := lrRun(t, "", "worktree", "new", "alpha", repo, "x", "--dry-run", "--link", "https://example.com/x"); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("%v", err)
	}
	text, _, err = lrRun(t, "", "worktree", "new", "alpha", repo, "a b", "--dry-run")
	if err != nil || !strings.Contains(text, "branch name") {
		t.Fatalf("%q %v", text, err)
	}
}

func TestWorktreeEditGoal(t *testing.T) {
	s, p, repo := wtCLI(t)
	if _, _, err := lrRun(t, "", "worktree", "new", "alpha", repo, "fix-login", "--goal", "First goal"); err != nil {
		t.Fatal(err)
	}
	out, _, err := lrRun(t, "", "worktree", "edit", "alpha", "fix-login", "--goal", "Fix the login form", "--json")
	if err != nil {
		t.Fatal(err)
	}
	edit := decodeWorktree(t, out)
	if edit.ChangeID == 0 || edit.Plot != p.ID || edit.Worktree.Goal != "Fix the login form" || edit.Worktree.Version != edit.ChangeID {
		t.Fatalf("%+v", edit)
	}
	item := store.WorktreeItem(edit.Worktree.ID)
	cs, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID, SinceID: edit.ChangeID - 1})
	if len(cs) != 1 || cs[0].Entries[0].Item != item || cs[0].Entries[0].Field != "goal" {
		t.Fatalf("changes %+v", cs)
	}
	if text, _, err := lrRun(t, "", "changes", "alpha"); err != nil || !strings.Contains(text, item+` goal: "First goal" -> "Fix the login form"`) {
		t.Fatalf("%q %v", text, err)
	}

	// A stale --expect writes nothing and names the current version.
	_, _, err = lrRun(t, "", "worktree", "edit", "alpha", "fix-login", "--goal", "Mine", "--expect", item+"=0")
	var stale *store.StaleError
	if !errors.As(err, &stale) || stale.Items[0].Worktree == nil || !strings.Contains(err.Error(), item+" is now at version "+lrItoa(edit.ChangeID)) {
		t.Fatalf("%v", err)
	}
	if text, _, err := lrRun(t, "", "worktree", "edit", "alpha", "fix-login", "--goal", "Mine", "--expect", item+"="+lrItoa(edit.ChangeID)); err != nil ||
		!strings.Contains(text, "Set the goal of app-fix-login.") {
		t.Fatalf("%q %v", text, err)
	}
	if text, _, err := lrRun(t, "", "worktree", "edit", "alpha", "fix-login", "--goal", "Mine"); err != nil || !strings.Contains(text, "No change.") {
		t.Fatalf("%q %v", text, err)
	}
	// A long goal saves with a warning.
	_, errOut, err := lrRun(t, "", "worktree", "edit", "alpha", "fix-login", "--goal", strings.Repeat("word ", 21))
	if err != nil || !strings.Contains(errOut, "The goal has 21 words. The soft limit is 20 words. Shorten it.") {
		t.Fatalf("%q %v", errOut, err)
	}
	// Undo puts the goal back.
	last, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID, Newest: true, Limit: 1})
	if _, _, err := lrRun(t, "", "undo", lrItoa(last[0].ID)); err != nil {
		t.Fatal(err)
	}
	if w, _ := s.GetWorktree(edit.Worktree.ID); w.Goal != "Mine" {
		t.Fatalf("goal %q", w.Goal)
	}
	// The command needs --goal, and a worktree of the plot.
	if _, _, err := lrRun(t, "", "worktree", "edit", "alpha", "fix-login"); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("%v", err)
	}
	if _, _, err := lrRun(t, "", "worktree", "edit", "alpha", "nosuch", "--goal", "x"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("%v", err)
	}
	// An empty goal clears it.
	if _, _, err := lrRun(t, "", "worktree", "edit", "alpha", "fix-login", "--goal", ""); err != nil {
		t.Fatal(err)
	}
	if w, _ := s.GetWorktree(edit.Worktree.ID); w.Goal != "" {
		t.Fatalf("goal %q", w.Goal)
	}
}

// A goal is one line. A goal with a line break keeps the layout of the text output.
func TestWorktreeGoalPrintsOnOneLine(t *testing.T) {
	_, _, repo := wtCLI(t)
	text, _, err := lrRun(t, "", "worktree", "new", "alpha", repo, "fix-login", "--goal", "Fix the\nlogin  form")
	if err != nil || !strings.Contains(text, "Goal: Fix the login form\n") {
		t.Fatalf("%q %v", text, err)
	}
	if text, _, err = lrRun(t, "", "worktree", "list", "alpha"); err != nil || !strings.Contains(text, "    Fix the login form\n") {
		t.Fatalf("%q %v", text, err)
	}
}

func TestUndoGoalOfARemovedWorktree(t *testing.T) {
	s, p, repo := wtCLI(t)
	if _, _, err := lrRun(t, "", "worktree", "new", "alpha", repo, "fix-login"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := lrRun(t, "", "worktree", "edit", "alpha", "fix-login", "--goal", "Fix the login form"); err != nil {
		t.Fatal(err)
	}
	last, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID, Newest: true, Limit: 1})
	if _, _, err := lrRun(t, "", "worktree", "rm", "alpha", "fix-login"); err != nil {
		t.Fatal(err)
	}
	_, _, err := lrRun(t, "", "undo", lrItoa(last[0].ID))
	if !errors.Is(err, store.ErrNotFound) || !strings.Contains(err.Error(), "removed") {
		t.Fatalf("%v", err)
	}
}
