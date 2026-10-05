package worktree

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

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
}

// Remove removes a worktree of a plot: the folder, the git record, the local
// branch if it is merged, and the store record. The argument is as in [Find].
//
// It refuses while a pane is open in the worktree. Without Force, it also
// refuses a worktree with uncommitted changes or unpushed commits. It deletes
// the branch with `git branch -d` only, and it never touches a remote branch.
func Remove(s *store.Store, plotID, arg string, o RemoveOptions) (*RemoveResult, error) {
	w, err := Find(s, plotID, o.Repo, arg)
	if err != nil {
		return nil, err
	}
	panes, err := OpenPanes(AppStateDir(), o.OpenPanes)
	if err != nil {
		return nil, err
	}
	n := 0
	for _, p := range panes {
		if inside(p.Folder, w.Path) {
			n++
		}
	}
	if n > 0 {
		return nil, fmt.Errorf("%d pane(s) are open in %s. Close them, then remove the worktree: %w", n, filepath.Base(w.Path), ErrPanesOpen)
	}

	st := Inspect(w)
	if !o.Force {
		var why []string
		if st.Changed > 0 {
			why = append(why, fmt.Sprintf("%d file(s) with uncommitted changes", st.Changed))
		}
		if st.Unpushed > 0 {
			why = append(why, fmt.Sprintf("%d commit(s) that are not pushed", st.Unpushed))
		}
		if st.Error != "" {
			why = append(why, "a check failed: "+st.Error)
		}
		if len(why) > 0 {
			return nil, fmt.Errorf("%s has %s. Run again with --force to remove it anyway: %w", filepath.Base(w.Path), strings.Join(why, " and "), ErrUnsafe)
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
	if _, err := git(w.Repo, "branch", "-d", w.Branch); err == nil {
		res.BranchDeleted = true
	} else {
		res.BranchNote = fmt.Sprintf("Kept the branch %s. Git says it is not fully merged. Delete it yourself with git branch -D if you do not need it.", w.Branch)
	}
	if err := s.RemoveWorktree(w.ID); err != nil {
		return nil, err
	}
	return res, nil
}
