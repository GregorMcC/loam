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
	// DryRun checks the work and changes nothing. It skips the check of the
	// open panes: the app runs it while the panes are open, and closes them
	// after it.
	DryRun bool
}

// RemoveResult says what a removal did.
type RemoveResult struct {
	Worktree      store.Worktree `json:"worktree"`
	BranchDeleted bool           `json:"branch_deleted"`
	// BranchNote says why the local branch is still there.
	BranchNote string `json:"branch_note,omitempty"`
	// DryRun is true for a dry run, which removed nothing.
	DryRun bool `json:"dry_run,omitempty"`
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
// PR cache says that the PR of the branch is merged, and the work of the
// worktree is in the PR (see [workInPR]), no commit counts as unpushed, and
// it deletes the branch with `git branch -D`. Else it uses `git branch -d`.
// A land uses the same rule (see [CheckWorkAfterPR]). It never touches a
// remote branch.
func Remove(s *store.Store, plotID, arg string, o RemoveOptions) (*RemoveResult, error) {
	w, err := Find(s, plotID, o.Repo, arg)
	if err != nil {
		return nil, err
	}
	if !o.DryRun {
		n, err := panesIn(w, o.OpenPanes)
		if err != nil {
			return nil, err
		}
		if n > 0 {
			return nil, &panesOpenError{folder: filepath.Base(w.Path), n: n}
		}
	}

	st := Inspect(w)
	// Read the PR and check the work against it before the removal: a
	// failure here leaves the worktree as it was.
	head, err := mergedHead(s, w)
	if err != nil {
		return nil, err
	}
	inPR := workInPR(w, st, branchTip(w), head)
	if !o.Force {
		var why []string
		d := RefusalDetails{Refusal: RefusalUnsafeWork, CheckError: st.Error}
		if st.Changed > 0 {
			why = append(why, fmt.Sprintf("%d file(s) with uncommitted changes", st.Changed))
			d.Changed = st.Changed
		}
		if st.Unpushed > 0 && !inPR {
			why = append(why, fmt.Sprintf("%d commit(s) that are not pushed", st.Unpushed))
			d.Unpushed = st.Unpushed
		}
		if st.Error != "" {
			why = append(why, "a check failed: "+st.Error)
		}
		if len(why) > 0 {
			return nil, &unsafeError{folder: filepath.Base(w.Path), why: why, details: d}
		}
	}
	if o.DryRun {
		return &RemoveResult{Worktree: w, DryRun: true}, nil
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
	// branch, so git branch -d refuses. When the tip is in the merged PR,
	// GitHub has each commit of the branch, and -D loses nothing.
	flag := "-d"
	if inPR {
		flag = "-D"
	}
	_, err = git(w.Repo, "branch", flag, w.Branch)
	switch {
	case err == nil:
		res.BranchDeleted = true
	case inPR:
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

// The kinds of a refused removal, in [RefusalDetails].
const (
	RefusalUnsafeWork = "unsafe_work"
	RefusalOpenPanes  = "open_panes"
)

// RefusalDetails is the details of a refused removal in the JSON error. The
// app words the refusal from them, since the message names flags of the CLI
// (ticket 113).
type RefusalDetails struct {
	// Refusal is [RefusalUnsafeWork] or [RefusalOpenPanes].
	Refusal string `json:"refusal"`
	// Changed is the number of files with uncommitted changes.
	Changed int `json:"changed,omitempty"`
	// Unpushed is the number of commits that are not pushed and that the
	// merged PR does not hold.
	Unpushed int `json:"unpushed,omitempty"`
	// CheckError is the error of a check that failed.
	CheckError string `json:"check_error,omitempty"`
	// OpenPanes is the number of panes that are open in the worktree.
	OpenPanes int `json:"open_panes,omitempty"`
}

// unsafeError is the error of a removal that would lose work. It matches
// [ErrUnsafe].
type unsafeError struct {
	folder string
	// why lists the work that the removal would lose, for a person to read.
	why     []string
	details RefusalDetails
}

func (e *unsafeError) Error() string {
	return fmt.Sprintf("%s has %s. Run again with --force to remove it anyway: %v", e.folder, e.work(), ErrUnsafe)
}

// Is makes the error match [ErrUnsafe].
func (e *unsafeError) Is(target error) bool { return target == ErrUnsafe }

// ErrorDetails gives the details of the JSON error.
func (e *unsafeError) ErrorDetails() any { return e.details }

// work says what work the removal would lose.
func (e *unsafeError) work() string { return strings.Join(e.why, " and ") }

// panesOpenError is the error of a removal while a pane is open in the
// worktree. It matches [ErrPanesOpen].
type panesOpenError struct {
	folder string
	n      int
}

func (e *panesOpenError) Error() string {
	return fmt.Sprintf("%d pane(s) are open in %s. Close them, then remove the worktree: %v", e.n, e.folder, ErrPanesOpen)
}

// Is makes the error match [ErrPanesOpen].
func (e *panesOpenError) Is(target error) bool { return target == ErrPanesOpen }

// ErrorDetails gives the details of the JSON error.
func (e *panesOpenError) ErrorDetails() any {
	return RefusalDetails{Refusal: RefusalOpenPanes, OpenPanes: e.n}
}

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

// workInPR reports whether the work of the worktree is in the PR with the
// head prHead: no file has changes, HEAD and the branch tip are one commit,
// and that commit is prHead or an earlier commit of the PR (see
// [commitInPR]). For an earlier commit, the local repo must have prHead. A
// worktree whose folder is gone has no HEAD, so its branch tip decides. It is
// false when prHead is empty, and when git could not read the local checks.
//
// After a squash or rebase merge, GitHub can delete the branch, and a fetch
// prunes it. Then no remote branch holds the commits of the PR, but GitHub
// has them in the PR. [Remove] and a land of a merged PR use this rule.
func workInPR(w store.Worktree, st Status, tip, prHead string) bool {
	if tip == "" || st.Changed > 0 || st.localFailed {
		return false
	}
	if !st.Missing {
		if h, err := git(w.Path, "rev-parse", "HEAD"); err != nil || h != tip {
			return false
		}
	}
	return commitInPR(w.Repo, tip, prHead)
}

// branchTip returns the commit at the tip of the branch of the worktree, or
// "" when git cannot read it.
func branchTip(w store.Worktree) string {
	tip, err := git(w.Repo, "rev-parse", "--verify", "--quiet", "refs/heads/"+w.Branch)
	if err != nil {
		return ""
	}
	return tip
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
