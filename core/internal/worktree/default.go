package worktree

import (
	"fmt"
	"path/filepath"
)

// SwitchToDefault puts the normal checkout of a repo on the default branch of
// the remote, at the latest commit of the remote. A repo add calls it, so that
// a plot does not start on the branch of the last piece of work (ticket 91).
//
// It does nothing to a folder that is not a git repo, a repo with no commits
// or no remote, and a linked worktree, which is on its branch on purpose. A
// checkout with uncommitted changes to tracked files keeps its branch.
// Untracked files do not count. It never fails: what it could not do comes
// back as warnings for a person to read.
func SwitchToDefault(repo string) []string {
	if !gitOK(repo, "rev-parse", "--verify", "--quiet", "HEAD") || !hasRemote(repo, remote) {
		return nil
	}
	gitDir, err1 := git(repo, "rev-parse", "--absolute-git-dir")
	common, err2 := git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if err1 != nil || err2 != nil || filepath.Clean(gitDir) != filepath.Clean(common) {
		return nil
	}
	name := filepath.Base(repo)
	current, _ := git(repo, "branch", "--show-current")
	if current == "" {
		current = "a detached HEAD"
		// Commits that no branch holds would be left behind in the reflog.
		if out, err := git(repo, "for-each-ref", "--count=1", "--contains", "HEAD", "refs/heads", "refs/remotes"); err != nil || out == "" {
			return []string{fmt.Sprintf("%s is on a detached HEAD with commits that no branch holds, so Loam left it there.", name)}
		}
	}
	if out, err := git(repo, "status", "--porcelain", "--untracked-files=no"); err != nil || out != "" {
		return []string{fmt.Sprintf("%s has uncommitted changes, so Loam left it on %s.", name, current)}
	}

	var warnings []string
	if _, err := git(repo, "fetch", remote); err != nil {
		warnings = append(warnings, fmt.Sprintf("Could not fetch %s from %s (%v). Loam used the last fetched state.", name, remote, err))
	}
	def, err := defaultBranch(repo)
	if err != nil {
		return append(warnings, fmt.Sprintf("Loam left %s on %s: %v", name, current, err))
	}
	upstream := remote + "/" + def
	hasUpstream := gitOK(repo, "show-ref", "--verify", "--quiet", "refs/remotes/"+upstream)
	switch {
	case current == def:
	case gitOK(repo, "show-ref", "--verify", "--quiet", "refs/heads/"+def):
		if _, err := git(repo, "switch", def); err != nil {
			return append(warnings, fmt.Sprintf("Loam could not switch %s to %s: %v", name, def, err))
		}
	case hasUpstream:
		if _, err := git(repo, "switch", "--track", "-c", def, upstream); err != nil {
			return append(warnings, fmt.Sprintf("Loam could not switch %s to %s: %v", name, def, err))
		}
	default:
		return append(warnings, fmt.Sprintf("Loam left %s on %s: the repo has no branch %s.", name, current, def))
	}
	if hasUpstream {
		if _, err := git(repo, "merge", "--ff-only", "--quiet", upstream); err != nil {
			warnings = append(warnings, fmt.Sprintf("%s is on %s, but Loam could not fast-forward it to %s. The two have diverged.", name, def, upstream))
		}
	}
	return warnings
}
