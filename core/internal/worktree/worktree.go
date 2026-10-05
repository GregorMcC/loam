package worktree

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/GregorMcC/loam/core/internal/store"
)

// remote is the remote that Loam fetches from and branches from.
const remote = "origin"

// CreateOptions says which worktree to make.
type CreateOptions struct {
	PlotID string
	// Repo is a repo ID or an absolute path of a repo of the plot.
	Repo string
	// Name is the name of the worktree. It is the branch name.
	Name string
	// Base is the branch that a new branch starts from. Empty means the
	// default branch of the remote. It does not apply to a branch that exists.
	Base string
}

// CreateResult is a new worktree.
type CreateResult struct {
	Worktree store.Worktree
	// Copied lists the files that were copied from the repo, relative to its root.
	Copied []string
	// Warnings are for a person to read: a failed fetch, a file that was not copied.
	Warnings []string
}

// FindRepo returns the repo of the plot that the argument names: a repo ID or a path.
func FindRepo(p store.Plot, arg string) (store.Repo, error) {
	for _, r := range p.Repos {
		if r.ID == arg {
			return r, nil
		}
	}
	abs, err := filepath.Abs(arg)
	if err != nil {
		abs = arg
	}
	for _, r := range p.Repos {
		if r.Path == arg || r.Path == abs {
			return r, nil
		}
	}
	return store.Repo{}, fmt.Errorf("no repo %q in plot %s: %w", arg, p.Name, store.ErrNotFound)
}

// folderName is the folder of a worktree: <repo folder name>-<name>. A slash
// in the name becomes a dash.
func folderName(repoPath, name string) string {
	return filepath.Base(repoPath) + "-" + strings.ReplaceAll(name, "/", "-")
}

// validName checks the name as a branch name.
func validName(repo, name string) error {
	if name == "" || strings.HasPrefix(name, "-") || strings.TrimSpace(name) != name ||
		!gitOK(repo, "check-ref-format", "--branch", name) {
		return fmt.Errorf("%q is not a good worktree name. Use a branch name: %w", name, store.ErrInvalid)
	}
	return nil
}

// Create makes a worktree for a repo of a plot.
//
// If a branch with the name exists, the worktree uses it. A local branch wins
// over a branch on the remote. Otherwise Create fetches from the remote and
// starts a new branch from Base, or from the default branch of the remote. A
// failed fetch is a warning. The new branch has no upstream.
//
// Create copies the files of the repo settings and of .worktreeinclude. It
// does not run the setup command.
func Create(s *store.Store, o CreateOptions) (*CreateResult, error) {
	plot, err := s.GetPlot(o.PlotID)
	if err != nil {
		return nil, err
	}
	repo, err := FindRepo(plot, o.Repo)
	if err != nil {
		return nil, err
	}
	if fi, err := os.Stat(repo.Path); err != nil || !fi.IsDir() {
		return nil, fmt.Errorf("the repo folder %s is missing. Fix the repo path, then try again", repo.Path)
	}
	if !gitOK(repo.Path, "rev-parse", "--git-dir") {
		return nil, fmt.Errorf("%s is not a git repo", repo.Path)
	}
	if err := validName(repo.Path, o.Name); err != nil {
		return nil, err
	}

	dest := filepath.Join(s.Home(), "worktrees", plot.ID, folderName(repo.Path, o.Name))
	existing, err := s.ListWorktrees(plot.ID)
	if err != nil {
		return nil, err
	}
	for _, w := range existing {
		if w.Path == dest || (w.Repo == repo.Path && w.Name == o.Name) {
			return nil, fmt.Errorf("the plot already has the worktree %s: %w", filepath.Base(w.Path), store.ErrDuplicate)
		}
	}
	if _, err := os.Lstat(dest); err == nil {
		return nil, fmt.Errorf("the folder %s exists: %w", dest, store.ErrDuplicate)
	}

	res := &CreateResult{}
	remoteOn := hasRemote(repo.Path, remote)
	if remoteOn {
		if _, err := git(repo.Path, "fetch", remote); err != nil {
			res.Warnings = append(res.Warnings, fmt.Sprintf("Could not fetch from %s (%v). The worktree starts from the last fetched state.", remote, err))
		}
	}

	localBranch := gitOK(repo.Path, "show-ref", "--verify", "--quiet", "refs/heads/"+o.Name)
	remoteBranch := remoteOn && gitOK(repo.Path, "show-ref", "--verify", "--quiet", "refs/remotes/"+remote+"/"+o.Name)
	base := ""
	made := false // a new branch that this call makes
	var add []string
	switch {
	case localBranch || remoteBranch:
		if o.Base != "" {
			return nil, fmt.Errorf("the branch %s exists, so --base does not apply: %w", o.Name, store.ErrInvalid)
		}
		if localBranch {
			add = []string{"worktree", "add", dest, o.Name}
		} else {
			add = []string{"worktree", "add", "--track", "-b", o.Name, dest, remote + "/" + o.Name}
			made = true
		}
	default:
		ref, name, err := resolveBase(repo.Path, remoteOn, o.Base)
		if err != nil {
			return nil, err
		}
		base = name
		add = []string{"worktree", "add", "--no-track", "-b", o.Name, dest, ref}
		made = true
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return nil, err
	}
	if _, err := git(repo.Path, add...); err != nil {
		return nil, err
	}

	rec, err := s.AddWorktree(store.Worktree{PlotID: plot.ID, Repo: repo.Path, Name: o.Name, Branch: o.Name, Base: base, Path: dest})
	if err != nil {
		// Undo the git steps; the record failed. The new branch holds no work yet.
		git(repo.Path, "worktree", "remove", "--force", dest)
		if made {
			git(repo.Path, "branch", "-D", o.Name)
		}
		return nil, err
	}
	res.Worktree = rec

	quiet := map[string]bool{}
	patterns := append([]string{}, repo.Copy...)
	for _, p := range worktreeInclude(repo.Path) {
		quiet[p] = true
		patterns = append(patterns, p)
	}
	copied, warnings := copyFiles(repo.Path, dest, patterns, quiet)
	res.Copied = copied
	res.Warnings = append(res.Warnings, warnings...)
	return res, nil
}

// resolveBase finds the ref to branch from and the name to record. With no
// base it takes the default branch of the remote. A base that names a local
// branch uses that branch, so its commits that are not pushed come along. A
// base such as "origin/main" uses the remote branch.
func resolveBase(repo string, remoteOn bool, base string) (ref, name string, err error) {
	if base != "" && !strings.HasPrefix(base, remote+"/") && gitOK(repo, "show-ref", "--verify", "--quiet", "refs/heads/"+base) {
		return base, base, nil
	}
	if base == "" {
		if !remoteOn {
			return "", "", fmt.Errorf("the repo has no remote called %s. Give --base <branch> to branch from a local branch: %w", remote, store.ErrInvalid)
		}
		def, err := defaultBranch(repo)
		if err != nil {
			return "", "", err
		}
		base = def
	}
	b := strings.TrimPrefix(base, remote+"/")
	if remoteOn && gitOK(repo, "show-ref", "--verify", "--quiet", "refs/remotes/"+remote+"/"+b) {
		return remote + "/" + b, remote + "/" + b, nil
	}
	if gitOK(repo, "show-ref", "--verify", "--quiet", "refs/heads/"+b) {
		return b, b, nil
	}
	return "", "", fmt.Errorf("the base branch %q is not in the repo: %w", base, store.ErrNotFound)
}

// defaultBranch returns the default branch of the remote, such as "main". It
// asks the remote. If that fails, it reads the last fetched origin/HEAD.
func defaultBranch(repo string) (string, error) {
	if out, err := git(repo, "ls-remote", "--symref", remote, "HEAD"); err == nil {
		for _, line := range strings.Split(out, "\n") {
			if ref, ok := strings.CutPrefix(line, "ref: refs/heads/"); ok {
				if name, _, ok := strings.Cut(ref, "\t"); ok && name != "" {
					return name, nil
				}
			}
		}
	}
	if out, err := git(repo, "symbolic-ref", "--short", "refs/remotes/"+remote+"/HEAD"); err == nil && out != "" {
		return strings.TrimPrefix(out, remote+"/"), nil
	}
	return "", fmt.Errorf("cannot find the default branch of %s. Give --base <branch>: %w", remote, store.ErrInvalid)
}

// Find returns a worktree of the plot. The argument is a worktree ID, a path,
// the folder name (such as "app-fix-x"), or the name. A name that two repos
// share needs the repo.
func Find(s *store.Store, plotID, repoArg, arg string) (store.Worktree, error) {
	all, err := s.ListWorktrees(plotID)
	if err != nil {
		return store.Worktree{}, err
	}
	if repoArg != "" {
		plot, err := s.GetPlot(plotID)
		if err != nil {
			return store.Worktree{}, err
		}
		r, err := FindRepo(plot, repoArg)
		if err != nil {
			return store.Worktree{}, err
		}
		kept := all[:0:0]
		for _, w := range all {
			if w.Repo == r.Path {
				kept = append(kept, w)
			}
		}
		all = kept
	}
	for _, match := range []func(store.Worktree) bool{
		func(w store.Worktree) bool { return w.ID == arg },
		func(w store.Worktree) bool { return w.Path == arg || w.Path == filepath.Clean(arg) },
		func(w store.Worktree) bool { return filepath.Base(w.Path) == arg },
		func(w store.Worktree) bool { return w.Name == arg },
	} {
		var hits []store.Worktree
		for _, w := range all {
			if match(w) {
				hits = append(hits, w)
			}
		}
		switch len(hits) {
		case 0:
			continue
		case 1:
			return hits[0], nil
		}
		names := make([]string, len(hits))
		for i, w := range hits {
			names[i] = filepath.Base(w.Path)
		}
		return store.Worktree{}, fmt.Errorf("%q matches more than one worktree (%s). Give the repo with --repo: %w", arg, strings.Join(names, ", "), store.ErrInvalid)
	}
	return store.Worktree{}, fmt.Errorf("no worktree %q in this plot: %w", arg, store.ErrNotFound)
}

// Status is the state of a worktree: what a removal would lose.
type Status struct {
	Worktree store.Worktree `json:"worktree"`
	// Missing is true when the worktree folder is gone.
	Missing bool `json:"missing"`
	// Changed counts the files with uncommitted changes, untracked files included.
	Changed int `json:"changed"`
	// Unpushed counts the commits of the branch that no remote branch holds.
	Unpushed int `json:"unpushed"`
	// Merged is true when the branch holds nothing that MergedInto lacks.
	Merged     bool   `json:"merged"`
	MergedInto string `json:"merged_into,omitempty"`
	// Error says why a check failed. A failed check counts as unsafe.
	Error string `json:"error,omitempty"`
}

// Inspect runs the checks on a worktree. It reads the last fetched state and
// does not use the network.
func Inspect(w store.Worktree) Status {
	st := Status{Worktree: w}
	if fi, err := os.Stat(w.Path); err != nil || !fi.IsDir() {
		st.Missing = true
	} else if out, err := git(w.Path, "status", "--porcelain"); err != nil {
		st.Error = err.Error()
	} else if out != "" {
		st.Changed = len(strings.Split(out, "\n"))
	}

	// Count the branch and, when the folder is there, the commit that the
	// worktree has checked out. A detached HEAD can hold commits that no
	// branch has.
	dir, args := w.Repo, []string{"rev-list", "--count", "refs/heads/" + w.Branch}
	if !st.Missing {
		dir, args = w.Path, append(args, "HEAD")
	}
	if out, _ := git(w.Repo, "for-each-ref", "--count=1", "refs/remotes"); out != "" {
		args = append(args, "--not", "--remotes")
	} else if w.Base != "" {
		args = append(args, "--not", w.Base) // no remote: count what the base branch lacks
	} else {
		args = nil
	}
	if args != nil {
		if out, err := git(dir, args...); err != nil {
			st.Error = err.Error()
		} else if n, err := strconv.Atoi(out); err == nil {
			st.Unpushed = n
		}
	}

	target := ""
	if out, err := git(w.Repo, "symbolic-ref", "--short", "refs/remotes/"+remote+"/HEAD"); err == nil && out != "" {
		target = out
	} else if w.Base != "" {
		target = w.Base
	}
	if target != "" {
		st.MergedInto = target
		_, err := git(w.Repo, "merge-base", "--is-ancestor", "refs/heads/"+w.Branch, target)
		st.Merged = err == nil
		if err != nil && exitCode(err) != 1 {
			st.Error = err.Error()
		}
	}
	return st
}

// List inspects the worktrees of a plot, oldest first. An empty plotID lists every plot.
func List(s *store.Store, plotID string) ([]Status, error) {
	ws, err := s.ListWorktrees(plotID)
	if err != nil {
		return nil, err
	}
	out := make([]Status, len(ws))
	for i, w := range ws {
		out[i] = Inspect(w)
	}
	return out, nil
}
