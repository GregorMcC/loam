package worktree

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/GregorMcC/loam/core/internal/store"
)

// RebuildError is why [Rebuild] does not rebuild the git metadata of a
// worktree. Its text names the folder of the worktree.
type RebuildError struct{ msg string }

func (e *RebuildError) Error() string { return e.msg }

// Rebuild checks that git knows the worktree w, and rebuilds its metadata
// when it is gone. The metadata of a worktree is in <git folder>/worktrees/
// <name> of its repo, which the session of a run can write: there, git
// worktree prune deletes the metadata of each worktree whose folder the
// sandbox does not show. Rebuild writes gitdir, commondir, and HEAD on the
// branch of w in that folder, then runs git reset -q in w, which rebuilds the
// index and leaves the files. It reports true when it rebuilt the metadata.
//
// It changes nothing, and reports false, when the metadata is there, and
// when the folder of w or its .git file is gone: the work that follows finds
// such a worktree gone. It returns a *RebuildError, and changes nothing, when
// the branch of w is gone, or when the .git file of w names a folder outside
// the git folder of the repo.
//
// Rebuild does not ask git for the git folder: git follows a commondir file
// in it, which the run can write to name another repo. It takes the .git
// folder of w.Repo, as the sandbox of a run does.
func Rebuild(ctx context.Context, w store.Worktree) (bool, error) {
	dotgit := filepath.Join(w.Path, ".git")
	fi, err := os.Lstat(dotgit)
	if err != nil || !fi.Mode().IsRegular() {
		return false, nil
	}
	b, err := os.ReadFile(dotgit)
	if err != nil {
		return false, err
	}
	admin, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "gitdir: ")
	if !ok {
		return false, &RebuildError{fmt.Sprintf("%s names no git folder", dotgit)}
	}
	if !filepath.IsAbs(admin) {
		admin = filepath.Join(w.Path, admin)
	}
	admin = filepath.Clean(admin)
	switch _, err := os.Lstat(admin); {
	case err == nil:
		return false, nil
	case !errors.Is(err, fs.ErrNotExist):
		return false, err
	}
	common := filepath.Join(w.Repo, ".git")
	parent := filepath.Dir(admin)
	if !realDir(common) || filepath.Base(parent) != "worktrees" || !sameDir(filepath.Dir(parent), common) {
		return false, &RebuildError{fmt.Sprintf(
			"The git metadata of %s is gone, and Loam does not rebuild it: its .git file names %s, which is outside the git folder %s", w.Path, admin, common)}
	}
	if w.Branch == "" || !gitOK(w.Repo, "rev-parse", "--verify", "--quiet", "refs/heads/"+w.Branch) {
		return false, &RebuildError{fmt.Sprintf(
			"The git metadata of %s is gone, and Loam does not rebuild it: the branch %s is gone", w.Path, w.Branch)}
	}
	worktrees := filepath.Join(common, "worktrees")
	if fi, err := os.Lstat(worktrees); err == nil && !fi.IsDir() {
		return false, &RebuildError{fmt.Sprintf(
			"The git metadata of %s is gone, and Loam does not rebuild it: %s is not a folder", w.Path, worktrees)}
	}
	if err := os.MkdirAll(worktrees, 0o755); err != nil {
		return false, err
	}
	if wrote, err := writeAdmin(common, admin, gitdirOf(w.Path), w.Branch); !wrote || err != nil {
		return false, err
	}
	if _, err := gitContext(ctx, w.Path, "reset", "-q"); err != nil {
		// The next check tries again from the start.
		_ = os.RemoveAll(admin)
		return false, fmt.Errorf("rebuild the index of %s: %w", w.Path, err)
	}
	return true, nil
}

// writeAdmin writes the metadata of a worktree in a new folder in common,
// then moves the folder to admin. Git sees no metadata in admin until it is
// whole. When another process rebuilt admin first, writeAdmin keeps that one
// and reports false: that process rebuilds the index.
func writeAdmin(common, admin, gitdir, branch string) (bool, error) {
	tmp, err := os.MkdirTemp(common, "loam-worktree-")
	if err != nil {
		return false, err
	}
	defer os.RemoveAll(tmp)
	files := []struct{ name, text string }{
		{"gitdir", gitdir + "\n"},
		{"commondir", "../..\n"},
		{"HEAD", "ref: refs/heads/" + branch + "\n"},
	}
	for _, f := range files {
		if err := os.WriteFile(filepath.Join(tmp, f.name), []byte(f.text), 0o644); err != nil {
			return false, err
		}
	}
	if err := os.Chmod(tmp, 0o755); err != nil {
		return false, err
	}
	if err := os.Rename(tmp, admin); err != nil {
		if _, serr := os.Lstat(admin); serr == nil {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// gitdirOf is the path of the .git file of the worktree in dir, by its real
// path, as git worktree add writes it in the gitdir file.
func gitdirOf(dir string) string {
	if r, err := filepath.EvalSymlinks(dir); err == nil {
		dir = r
	}
	return filepath.Join(dir, ".git")
}

// realDir reports whether path is a folder, and not a link to one.
func realDir(path string) bool {
	fi, err := os.Lstat(path)
	return err == nil && fi.IsDir()
}

// sameDir reports whether a and b are the same folder.
func sameDir(a, b string) bool {
	fa, err := os.Stat(a)
	if err != nil {
		return false
	}
	fb, err := os.Stat(b)
	return err == nil && os.SameFile(fa, fb)
}
