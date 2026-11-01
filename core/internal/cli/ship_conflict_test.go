package cli

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TAS-218: a PR that conflicts with its base goes back to the session to
// merge the base, not to Ready.

// mergeState is ciState with the mergeable and the merge state of GitHub.
func mergeState(branch, head, conclusion, mergeable, state string) string {
	return strings.Replace(ciState(branch, head, conclusion), `"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN"`,
		`"mergeable": "`+mergeable+`", "mergeStateStatus": "`+state+`"`, 1)
}

func conflicting(branch, head string) string {
	return mergeState(branch, head, "SUCCESS", "CONFLICTING", "DIRTY")
}

// landOnMain puts a commit on main on GitHub that conflicts with the run:
// another hello.txt. It returns the new head of main.
func landOnMain(t *testing.T, w store.Worktree) string {
	t.Helper()
	if err := os.WriteFile(filepath.Join(w.Repo, "hello.txt"), []byte("hello from main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	testutil.Git(t, w.Repo, "add", "hello.txt")
	testutil.Git(t, w.Repo, "commit", "-q", "-m", "Say hello on main")
	testutil.Git(t, w.Repo, "push", "-q", "origin", "main")
	return testutil.Git(t, w.Repo, "rev-parse", "HEAD")
}

// endTurn ends a turn of the session through the gate, which must pass.
func endTurn(t *testing.T, r store.Run) {
	t.Helper()
	if code, reason := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("gate: %d %s", code, reason)
	}
}

// A PR whose CI passed and that conflicts with main goes back to the session,
// not to Ready. Loam fetches main first, the send-back counts no try, and the
// merge comes back through the gate and Ship. When GitHub shows the merge as
// MERGEABLE, the run is Ready.
func TestRunTickSendsAConflictingPRBackToMergeItsBase(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	main := landOnMain(t, w)
	setGitHub(t, conflicting(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD")))
	got := tick(t)
	note := "#1 conflicts with main. Loam sends the run back to merge main (conflict send-back 1 of 2)"
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].Note != note ||
		got.Runs[0].Tries != 0 || got.Runs[0].ReviewTries != 0 {
		t.Fatalf("%+v", got)
	}
	if fetched := testutil.Git(t, r.Folder, "rev-parse", "refs/remotes/origin/main"); fetched != main {
		t.Fatalf("origin/main is %s, not the head of main %s", fetched, main)
	}
	prompt := lastPrompt(t)
	for _, want := range []string{"#1 conflicts with main", "`git merge origin/main`", "- hello.txt",
		"keep the behaviour of both sides", "commit the merge", "Do not run the Done when checks yourself"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("the prompt misses %q:\n%s", want, prompt)
		}
	}
	if e := events(t, s, r.ID, "conflict"); len(e) != 1 || e[0] != note {
		t.Fatalf("conflict events %q", e)
	}
	if e := events(t, s, r.ID, "ci"); len(e) != 0 {
		t.Fatalf("Loam read CI on a PR that conflicts: %q", e)
	}

	// The session merges main, and Loam pushes the merge.
	if _, err := gitIn(r.Folder, "merge", "origin/main"); err == nil {
		t.Fatal("the merge did not conflict")
	}
	writeAndCommit(t, r.Folder, "hello.txt", "hello from main\nhi there\n")
	endTurn(t, r)
	tick(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	remote := filepath.Join(filepath.Dir(filepath.Dir(w.Repo)), "remote.git")
	if testutil.Git(t, remote, "rev-parse", w.Branch) != head {
		t.Fatal("the merge is not on GitHub")
	}
	setGitHub(t, ciState(w.Branch, head, "SUCCESS"))
	if got := tick(t); len(got.Runs) != 1 || got.Runs[0].State != store.RunReady {
		t.Fatalf("%+v", got)
	}
	if r, _ = s.GetRun(r.ID); r.ConflictSends != 0 || r.ConflictHead != "" {
		t.Fatalf("a PR that can merge keeps the conflict count: %d %s", r.ConflictSends, r.ConflictHead)
	}
}

// A Ready run goes back the same way when another PR lands and its PR
// conflicts.
func TestRunTickSendsAReadyRunBackWhenItsPRConflicts(t *testing.T) {
	s, r, w := readyRun(t)
	landOnMain(t, w)
	setGitHub(t, conflicting(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD")))
	got := tick(t)
	note := "#1 conflicts with main. Loam sends the run back to merge main (conflict send-back 1 of 2)"
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].Note != note || got.Runs[0].Tries != 0 {
		t.Fatalf("%+v", got)
	}
	if !strings.Contains(lastPrompt(t), "`git merge origin/main`") {
		t.Fatalf("prompt %s", lastPrompt(t))
	}
	if e := events(t, s, r.ID, "conflict"); len(e) != 1 {
		t.Fatalf("conflict events %q", e)
	}
}

// While GitHub computes whether the PR can merge, the tick changes nothing,
// in Shipping and in Ready.
func TestRunTickWaitsWhileGitHubChecksWhetherThePRCanMerge(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, mergeState(w.Branch, head, "SUCCESS", "UNKNOWN", "UNKNOWN"))
	if got := tick(t); len(got.Runs) != 0 {
		t.Fatalf("%+v", got)
	}
	if r, _ = s.GetRun(r.ID); r.State != store.RunShipping {
		t.Fatalf("%+v", r)
	}
	setGitHub(t, ciState(w.Branch, head, "SUCCESS"))
	if got := tick(t); len(got.Runs) != 1 || got.Runs[0].State != store.RunReady {
		t.Fatalf("%+v", got)
	}
	setGitHub(t, mergeState(w.Branch, head, "SUCCESS", "UNKNOWN", "UNKNOWN"))
	if got := tick(t); len(got.Runs) != 0 {
		t.Fatalf("%+v", got)
	}
	if r, _ = s.GetRun(r.ID); r.State != store.RunReady {
		t.Fatalf("%+v", r)
	}
}

// Loam sends one conflict send-back for each head, and 2 in a row. A PR that
// still conflicts on the third head stops the run, and the note names the
// files that conflict.
func TestRunTickStopsARunAtTheThirdConflictInARow(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	landOnMain(t, w)
	setGitHub(t, conflicting(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD")))
	tick(t)
	for i, file := range []string{"one.txt", "two.txt"} {
		// The session commits, but does not merge main.
		writeAndCommit(t, r.Folder, file, "not a merge\n")
		endTurn(t, r)
		tick(t) // pushes the new head
		setGitHub(t, conflicting(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD")))
		got := tick(t)
		if i == 0 {
			note := "#1 conflicts with main. Loam sends the run back to merge main (conflict send-back 2 of 2)"
			if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].Note != note {
				t.Fatalf("second conflict: %+v", got)
			}
			continue
		}
		note := "#1 conflicts with main after 2 conflict send-backs in a row. Merge main into the branch yourself. The files that conflict: hello.txt"
		if len(got.Runs) != 1 || got.Runs[0].State != store.RunStopped || got.Runs[0].Note != note || got.Runs[0].Tries != 0 {
			t.Fatalf("third conflict: %+v", got)
		}
	}
	if e := events(t, s, r.ID, "conflict"); len(e) != 3 {
		t.Fatalf("conflict events %q", e)
	}
}

// A session that ends its turn with no merge commit leaves the PR head as it
// was: Loam sends no second send-back for that head, and the run stops.
func TestRunTickStopsARunWhoseSessionMadeNoMerge(t *testing.T) {
	_, r, w := shipRun(t, "3")
	tick(t)
	landOnMain(t, w)
	setGitHub(t, conflicting(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD")))
	tick(t)
	endTurn(t, r)
	got := tick(t)
	note := "#1 conflicts with main, and the session made no merge commit after the conflict send-back. Merge main into the branch yourself. The files that conflict: hello.txt"
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunStopped || got.Runs[0].Note != note {
		t.Fatalf("%+v", got)
	}
}

// The conflict send-backs of a PR do not count for a PR that the run adopts
// later, also on the same head.
func TestRunTickStartsTheConflictCountAgainForANewPR(t *testing.T) {
	_, r, w := shipRun(t, "3")
	tick(t)
	landOnMain(t, w)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, conflicting(w.Branch, head))
	tick(t)
	endTurn(t, r)
	// The branch now has another open PR, #2, at the same head.
	second := strings.NewReplacer(`"number": 1`, `"number": 2`, "/pull/1", "/pull/2", `"details": {"1"`, `"details": {"2"`).
		Replace(conflicting(w.Branch, head))
	setGitHub(t, second)
	if got := tick(t); len(got.Runs) != 1 || got.Runs[0].PR == nil || got.Runs[0].PR.Number != 2 {
		t.Fatalf("adopt: %+v", got)
	}
	got := tick(t)
	note := "#2 conflicts with main. Loam sends the run back to merge main (conflict send-back 1 of 2)"
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].Note != note {
		t.Fatalf("%+v", got)
	}
}

// A run folder whose HEAD is on another branch stops the run, because the
// merge of the session would not reach the PR.
func TestRunTickStopsAConflictWhenTheFolderIsOnAnotherBranch(t *testing.T) {
	_, r, w := shipRun(t, "3")
	tick(t)
	landOnMain(t, w)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	testutil.Git(t, r.Folder, "checkout", "-q", "-b", "elsewhere")
	setGitHub(t, conflicting(w.Branch, head))
	got := tick(t)
	note := "#1 conflicts with main, and the run folder is not on " + w.Branch + ". Check out " + w.Branch + ", then merge main into it yourself"
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunStopped || got.Runs[0].Note != note {
		t.Fatalf("%+v", got)
	}
	for _, c := range testutil.FakeClaudeCalls(t) {
		if slices.Contains(c, "--resume") {
			t.Fatalf("the session got a prompt: %q", c)
		}
	}
}

// gitIn runs git in dir and returns its output and error, for a command that
// can fail.
func gitIn(dir string, args ...string) (string, error) {
	out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput()
	return string(out), err
}
