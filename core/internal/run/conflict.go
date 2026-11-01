package run

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"

	"github.com/GregorMcC/loam/core/internal/gitcmd"
	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// maxConflictSends is how many conflict send-backs in a row Loam makes
// before it stops the run (TAS-218).
const maxConflictSends = 2

// fetchTimeout limits one git fetch of the base branch.
const fetchTimeout = pushTimeout

// conflictEvent is the kind of the event of a conflict send-back, and of the
// stop after the last one.
const conflictEvent = "conflict"

// conflicts reads whether pr can merge into its base branch, before Loam
// reads CI or makes the run Ready. pr is at the head of the branch in the
// worktree. A CONFLICTING PR goes back to the session to merge its base (see
// [shipper.sendConflict]), and done is true. While GitHub computes it
// (UNKNOWN), done is true too and nothing changes: the next tick reads it
// again. A MERGEABLE PR starts the count of conflict send-backs again. Any
// other value, such as from a fake GitHub with no merge state, is not a
// conflict.
func (sh *shipper) conflicts(ctx context.Context, w store.Worktree, pr *github.PR) (moved, done bool, err error) {
	switch pr.Mergeable {
	case "CONFLICTING":
		moved, err := sh.sendConflict(ctx, w, pr)
		return moved, true, err
	case "UNKNOWN":
		return false, true, nil
	case "MERGEABLE":
		if sh.r.ConflictSends == 0 && sh.r.ConflictHead == "" {
			return false, false, nil
		}
		// The record changes, but not what the run shows, so the run did not move.
		_, err := sh.update(func(r *store.Run) { r.ConflictSends, r.ConflictHead = 0, "" })
		return false, false, err
	}
	return false, false, nil
}

// sendConflict sends the run back to its session to merge the base branch of
// pr, which GitHub shows as CONFLICTING. The session cannot fetch, so Loam
// fetches the base first. The send-back counts no try and no review try, and
// the gate and the push follow as for a CI fix. Loam sends one send-back for
// each head, and at most [maxConflictSends] in a row: a PR that still
// conflicts after them, or on a head that already went back, stops the run,
// and the note names the files that conflict, for you to merge. A run folder
// whose HEAD is not on the branch of the run stops the run too, because the
// merge of the session would not reach the PR. A fetch that fails is an
// error, and the next tick tries again.
func (sh *shipper) sendConflict(ctx context.Context, w store.Worktree, pr *github.PR) (bool, error) {
	base := cmp.Or(pr.Base, worktree.CompareBase(w))
	if base == "" {
		return sh.move(store.RunStopped, fmt.Sprintf("#%d conflicts with its base branch, and Loam cannot tell which branch that is. Merge the base into the branch yourself", pr.Number))
	}
	if on, err := gitOut(ctx, sh.r.Folder, "symbolic-ref", "--quiet", "--short", "HEAD"); err != nil || on != w.Branch {
		// A merge there would not reach the branch of the PR.
		note := fmt.Sprintf("#%d conflicts with %s, and the run folder is not on %s. Check out %s, then merge %s into it yourself", pr.Number, base, w.Branch, w.Branch, base)
		if err := sh.s.AddRunEvent(sh.r.ID, conflictEvent, note); err != nil {
			return false, err
		}
		return sh.move(store.RunStopped, note)
	}
	if out, err := sh.fetchBase(ctx, base); err != nil {
		return false, errors.New(failureNote("git fetch of "+base+" failed", err, out))
	}
	files := conflictFiles(ctx, sh.r.Folder, "refs/remotes/origin/"+base, pr.HeadOID)
	conflicts := fmt.Sprintf("#%d conflicts with %s", pr.Number, base)
	var stop string
	switch {
	case sh.r.ConflictHead == pr.HeadOID:
		stop = fmt.Sprintf("%s, and the session made no merge commit after the conflict send-back", conflicts)
	case sh.r.ConflictSends >= maxConflictSends:
		stop = fmt.Sprintf("%s after %s in a row", conflicts, count(sh.r.ConflictSends, "conflict send-back"))
	}
	if stop != "" {
		note := stop + ". Merge " + base + " into the branch yourself"
		if len(files) > 0 {
			note += ". The files that conflict: " + strings.Join(files, ", ")
		}
		if err := sh.s.AddRunEvent(sh.r.ID, conflictEvent, note); err != nil {
			return false, err
		}
		return sh.move(store.RunStopped, note)
	}
	n := sh.r.ConflictSends + 1
	note := fmt.Sprintf("%s. Loam sends the run back to merge %s (conflict send-back %d of %d)", conflicts, base, n, maxConflictSends)
	if err := sh.s.AddRunEvent(sh.r.ID, conflictEvent, note); err != nil {
		return false, err
	}
	prompt := conflictPrompt(pr, base, files, n, hasChecks(sh.s, sh.r))
	head := pr.HeadOID
	return sh.resume(ctx, prompt, note, "conflict send-back", func(r *store.Run) {
		r.ConflictSends, r.ConflictHead = n, head
	})
}

// fetchBase updates origin/<base> in the worktree of the run, so the session
// can merge it. It returns the output of git.
func (sh *shipper) fetchBase(ctx context.Context, base string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, fetchTimeout)
	defer cancel()
	refspec := "+refs/heads/" + base + ":refs/remotes/origin/" + base
	out, err := gitcmd.Command(ctx, sh.r.Folder, "fetch", "--no-tags", "--no-recurse-submodules", "origin", refspec).CombinedOutput()
	return string(out), err
}

// conflictFiles lists the files that conflict when head merges base, from
// git merge-tree, which changes no file and no ref. It returns nil when git
// finds no conflict or cannot tell, such as a git before 2.38.
func conflictFiles(ctx context.Context, dir, base, head string) []string {
	out, err := gitcmd.Command(ctx, dir, "-c", "core.quotePath=off",
		"merge-tree", "--write-tree", "--name-only", "--no-messages", base, head).Output()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 1 {
		return nil // 0 is a clean merge, and other codes are errors
	}
	// The first line is the tree of the merge, and then each file that
	// conflicts, once.
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	var files []string
	for _, l := range lines[1:] {
		if l != "" {
			files = append(files, l)
		}
	}
	return files
}

// conflictPrompt is the prompt of a conflict send-back: the base branch to
// merge, the files that conflict when Loam knows them, and how to merge.
// checks is whether the run has checks (see [hasChecks]).
func conflictPrompt(pr *github.PR, base string, files []string, n int, checks bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "#%d conflicts with %s, its base branch, on GitHub (conflict send-back %d of %d). Loam fetched %s, so origin/%s is up to date in this folder.\n",
		pr.Number, base, n, maxConflictSends, base, base)
	if len(files) > 0 {
		b.WriteString("\nThese files conflict:\n")
		for _, f := range files {
			fmt.Fprintf(&b, "- %s\n", f)
		}
	}
	fmt.Fprintf(&b, "\nRun `git merge origin/%s`. In each conflict, keep the behaviour of both sides: the change of this branch and the change of %s. "+
		"Then run the tests of the code that the merge changed, commit the merge, and end your turn. "+
		"Do not rebase and do not fetch: Loam pushes the merge commit to #%d after the Done when checks pass.\n%s",
		base, base, pr.Number, checksLine(checks, leaveToGate))
	return b.String()
}
