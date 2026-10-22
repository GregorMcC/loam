package worktree

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
)

// Errors that callers test with errors.Is.
var (
	// ErrUnsafe means the worktree holds work that a removal would lose.
	// --force removes it anyway.
	ErrUnsafe = errors.New("the worktree holds work that is not saved")
	// ErrPanesOpen means a pane is open in the worktree. Force does not skip this check.
	ErrPanesOpen = errors.New("a pane is open in the worktree")
)

// Pane is an open pane of the app: its plot and its working folder.
type Pane struct {
	PlotID string `json:"plot_id"`
	Folder string `json:"folder"`
}

// StateFile is the name of the file in the app state folder where the app
// lists its panes. See docs/contract.md.
const StateFile = "state.json"

// AppStateDir returns the folder of the app's state.json:
// ~/Library/Application Support/Loam. LOAM_APP_STATE_DIR replaces it in tests.
func AppStateDir() string {
	if d := os.Getenv("LOAM_APP_STATE_DIR"); d != "" {
		return d
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "Loam")
}

// OpenPanes returns the panes in state.json in dir, and the extra folders that
// the caller passes. A missing state.json means no panes. A pane with no
// folder is skipped.
func OpenPanes(dir string, extra []string) ([]Pane, error) {
	var panes []Pane
	b, err := os.ReadFile(filepath.Join(dir, StateFile))
	switch {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return nil, fmt.Errorf("read %s: %w", StateFile, err)
	default:
		var st struct {
			Panes []Pane `json:"panes"`
		}
		if err := json.Unmarshal(b, &st); err != nil {
			return nil, fmt.Errorf("%s in %s is not valid JSON, so Loam cannot tell which panes are open. Fix or remove the file: %w", StateFile, dir, err)
		}
		panes = st.Panes
	}
	for _, f := range extra {
		panes = append(panes, Pane{Folder: f})
	}
	out := panes[:0:0]
	for _, p := range panes {
		if p.Folder != "" {
			out = append(out, p)
		}
	}
	return out, nil
}

// resolve returns the folder with links resolved, or the cleaned folder when
// it does not exist.
func resolve(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return filepath.Clean(p)
}

// inside reports whether folder is dir or a folder under it.
func inside(folder, dir string) bool {
	for _, f := range []string{filepath.Clean(folder), resolve(folder)} {
		for _, d := range []string{filepath.Clean(dir), resolve(dir)} {
			if f == d || strings.HasPrefix(f, d+string(filepath.Separator)) {
				return true
			}
		}
	}
	return false
}

// RemoveOptions says how to remove a worktree.
type RemoveOptions struct {
	// Force removes a worktree that has uncommitted changes or unpushed commits.
	Force bool
	// OpenPanes are folders of panes that the caller knows are open. Loam adds
	// the panes of state.json.
	OpenPanes []string
	// Repo picks the repo when two repos have a worktree with the same name.
	Repo string
}

// RemoveResult says what a removal did.
type RemoveResult struct {
	Worktree      store.Worktree `json:"worktree"`
	BranchDeleted bool           `json:"branch_deleted"`
	// BranchNote says why the local branch is still there.
	BranchNote string `json:"branch_note,omitempty"`
	// Warnings are for a person to read, such as a seed that was not written.
	// They are not in the JSON: the CLI prints them on stderr.
	Warnings []string `json:"-"`
}

// Remove removes a worktree of a plot: the folder, the git record, the local
// branch if it is merged, and the store record. Then it writes the seed of
// the plot again, because the seed lists the worktrees. The argument is as
// in [Find].
//
// It refuses while a pane is open in the worktree. Without Force, it also
// refuses a worktree with uncommitted changes or unpushed commits. When the
// PR cache says that the PR of the branch is merged, and HEAD and the branch
// tip are the PR head, the commits are in the PR, and none counts as
// unpushed. It deletes the branch with `git branch -d`. When the PR is merged
// and the branch tip is the PR head, it uses -D. It never touches a remote
// branch.
func Remove(s *store.Store, plotID, arg string, o RemoveOptions) (*RemoveResult, error) {
	w, err := Find(s, plotID, o.Repo, arg)
	if err != nil {
		return nil, err
	}
	n, err := panesIn(w, o.OpenPanes)
	if err != nil {
		return nil, err
	}
	if n > 0 {
		return nil, fmt.Errorf("%d pane(s) are open in %s. Close them, then remove the worktree: %w", n, filepath.Base(w.Path), ErrPanesOpen)
	}

	st := Inspect(w)
	// Read the branch tip and the PR before the removal: a failure here
	// leaves the worktree as it was.
	tip, _ := git(w.Repo, "rev-parse", "--verify", "--quiet", "refs/heads/"+w.Branch)
	head, err := mergedHead(s, w)
	if err != nil {
		return nil, err
	}
	if !o.Force {
		var why []string
		if st.Changed > 0 {
			why = append(why, fmt.Sprintf("%d file(s) with uncommitted changes", st.Changed))
		}
		if st.Unpushed > 0 && !inMergedPR(w, st, tip, head) {
			why = append(why, fmt.Sprintf("%d commit(s) that are not pushed", st.Unpushed))
		}
		if st.Error != "" {
			why = append(why, "a check failed: "+st.Error)
		}
		if len(why) > 0 {
			return nil, &unsafeError{folder: filepath.Base(w.Path), why: why}
		}
	}

	if st.Missing {
		git(w.Repo, "worktree", "prune")
	} else {
		args := []string{"worktree", "remove"}
		if o.Force {
			args = append(args, "--force")
		}
		if _, err := git(w.Repo, append(args, w.Path)...); err != nil {
			return nil, err
		}
	}

	res := &RemoveResult{Worktree: w}
	// A squash or rebase merge leaves the commits of the PR off the base
	// branch, so git branch -d refuses. When the tip is the head of the merged
	// PR, GitHub has each commit of the branch, and -D loses nothing.
	merged := tip != "" && tip == head
	flag := "-d"
	if merged {
		flag = "-D"
	}
	_, err = git(w.Repo, "branch", flag, w.Branch)
	switch {
	case err == nil:
		res.BranchDeleted = true
	case merged:
		res.BranchNote = fmt.Sprintf("Kept the branch %s: %v", w.Branch, err)
	default:
		res.BranchNote = fmt.Sprintf("Kept the branch %s. Git says it is not fully merged. Delete it yourself with git branch -D if you do not need it.", w.Branch)
	}
	if err := s.RemoveWorktree(w.ID); err != nil {
		return nil, err
	}
	if warning := seed.AfterWorktrees(s, plotID); warning != "" {
		res.Warnings = append(res.Warnings, warning)
	}
	return res, nil
}

// unsafeError is the error of a removal that would lose work. It matches
// [ErrUnsafe].
type unsafeError struct {
	folder string
	// why lists the work that the removal would lose, for a person to read.
	why []string
}

func (e *unsafeError) Error() string {
	return fmt.Sprintf("%s has %s. Run again with --force to remove it anyway: %v", e.folder, e.work(), ErrUnsafe)
}

// Is makes the error match [ErrUnsafe].
func (e *unsafeError) Is(target error) bool { return target == ErrUnsafe }

// work says what work the removal would lose.
func (e *unsafeError) work() string { return strings.Join(e.why, " and ") }

// panesIn counts the open panes in the worktree: the panes of state.json and
// the extra folders.
func panesIn(w store.Worktree, extra []string) (int, error) {
	panes, err := OpenPanes(AppStateDir(), extra)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, p := range panes {
		if inside(p.Folder, w.Path) {
			n++
		}
	}
	return n, nil
}

// inMergedPR reports whether the commits of the worktree are in the merged PR
// with the head: no file has changes, and HEAD and the branch tip are the
// head. A worktree whose folder is gone has no HEAD, so its branch tip
// decides. After a squash or rebase merge, GitHub can delete the branch, and
// a fetch prunes it. Then no remote branch holds the commits of the PR, but
// GitHub has them in the PR.
func inMergedPR(w store.Worktree, st Status, tip, head string) bool {
	if head == "" || tip != head || st.Changed > 0 || st.localFailed {
		return false
	}
	if st.Missing {
		return true
	}
	h, err := git(w.Path, "rev-parse", "HEAD")
	return err == nil && h == head
}

// mergedHead returns the head of the merged PR of the branch of the worktree
// from the PR cache. It is empty when the cache has no merged PR, or a head
// that is not a commit ID.
func mergedHead(s *store.Store, w store.Worktree) (string, error) {
	cache, err := s.PRStates()
	if err != nil {
		return "", err
	}
	c := decodeCached(cache[store.PRKey{Repo: w.Repo, Branch: w.Branch}])
	if c.PR == nil || c.PR.State != "MERGED" || !oidPattern.MatchString(c.PR.HeadOID) {
		return "", nil
	}
	return c.PR.HeadOID, nil
}
