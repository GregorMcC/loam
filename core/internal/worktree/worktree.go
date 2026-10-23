package worktree

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/gitremote"
	"github.com/GregorMcC/loam/core/internal/linkkind"
	"github.com/GregorMcC/loam/core/internal/seed"
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
	// Goal is one line that says what the worktree is for. It can be empty.
	Goal string
	// Link is the link that the work starts from: the ID of a link of the
	// plot, or the URL of a Linear issue or a GitHub issue. Empty means no
	// link. See [ResolveLink].
	Link string
}

// CreateResult is a new worktree.
type CreateResult struct {
	Worktree store.Worktree
	// Copied lists the files that were copied from the repo, relative to its root.
	Copied []string
	// Warnings are for a person to read: a failed fetch, a file that was not
	// copied, a goal over the soft limit, a seed that was not written.
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
	if problem := nameProblem(repo, name); problem != "" {
		return fmt.Errorf("%s: %w", problem, store.ErrInvalid)
	}
	return nil
}

// nameProblem says why the name is not a good branch name, or returns "".
func nameProblem(repo, name string) string {
	if name == "" || strings.HasPrefix(name, "-") || strings.TrimSpace(name) != name ||
		!gitOK(repo, "check-ref-format", "--branch", name) {
		return fmt.Sprintf("%q is not a good worktree name. Use a branch name", name)
	}
	return ""
}

// ResolveLink returns the link of a new worktree of repoPath from its
// argument: the ID of a link of the plot, or the URL of a Linear issue or a
// GitHub issue. A link of the plot keeps its label and records its ID. A URL
// takes its label from the target, and it does not go into the plot's links.
// The key of a GitHub issue is "#57" only when the issue is in the repo of
// origin (see [linkkind.IssueKey]). An empty argument gives no link.
func ResolveLink(p store.Plot, repoPath, arg string) (*store.WorktreeLink, error) {
	arg = strings.TrimSpace(arg)
	if arg == "" {
		return nil, nil
	}
	link := func(target, label, linkID string) *store.WorktreeLink {
		origin, _ := gitremote.Origin(repoPath)
		return &store.WorktreeLink{Target: target, Label: label, Key: linkkind.IssueKey(target, origin), LinkID: linkID}
	}
	if strings.Contains(arg, "://") {
		if linkkind.IssueKey(arg, "") == "" {
			return nil, fmt.Errorf("%s is not a Linear issue or a GitHub issue. Give the URL of an issue, or the ID of a link of the plot: %w", arg, store.ErrInvalid)
		}
		return link(arg, linkkind.Label(arg), ""), nil
	}
	for _, l := range p.Links {
		if l.ID == arg {
			return link(l.Target, l.Label, l.ID), nil
		}
	}
	return nil, fmt.Errorf("no link %q in plot %s. Give a link ID from loam show, or the URL of an issue: %w", arg, p.Name, store.ErrNotFound)
}

// newWorktree is what Create and Check work out before they make anything:
// the plot, the repo, the link, the folder, and whether the branch exists.
type newWorktree struct {
	plot store.Plot
	repo store.Repo
	link *store.WorktreeLink
	dest string
	// exists names the worktree or the folder that is already there, or is "".
	exists string
	// localBranch and remoteBranch say where a branch with the name exists.
	localBranch, remoteBranch bool
	remoteOn                  bool
}

// prepare runs the checks of Create that change nothing. A name that is not
// a good branch name fails only when checkName is true. The branch checks
// read the last fetched state, so Create calls refreshBranches after its fetch.
func prepare(s *store.Store, o CreateOptions, checkName bool) (*newWorktree, error) {
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
	if checkName {
		if err := validName(repo.Path, o.Name); err != nil {
			return nil, err
		}
	}
	link, err := ResolveLink(plot, repo.Path, o.Link)
	if err != nil {
		return nil, err
	}

	n := &newWorktree{plot: plot, repo: repo, link: link, remoteOn: hasRemote(repo.Path, remote),
		dest: filepath.Join(s.Home(), "worktrees", plot.ID, folderName(repo.Path, o.Name))}
	existing, err := s.ListWorktrees(plot.ID)
	if err != nil {
		return nil, err
	}
	for _, w := range existing {
		if w.Path == n.dest || (w.Repo == repo.Path && w.Name == o.Name) {
			n.exists = fmt.Sprintf("the plot already has the worktree %s", filepath.Base(w.Path))
		}
	}
	if _, err := os.Lstat(n.dest); n.exists == "" && err == nil {
		n.exists = fmt.Sprintf("the folder %s exists", n.dest)
	}
	n.refreshBranches(o.Name)
	return n, nil
}

// refreshBranches says whether a local branch or a branch of the remote has the name.
func (n *newWorktree) refreshBranches(name string) {
	n.localBranch = gitOK(n.repo.Path, "show-ref", "--verify", "--quiet", "refs/heads/"+name)
	n.remoteBranch = n.remoteOn && gitOK(n.repo.Path, "show-ref", "--verify", "--quiet", "refs/remotes/"+remote+"/"+name)
}

// Create makes a worktree for a repo of a plot.
//
// If a branch with the name exists, the worktree uses it. A local branch wins
// over a branch on the remote. Otherwise Create fetches from the remote and
// starts a new branch from Base, or from the default branch of the remote. A
// failed fetch is a warning. The new branch has no upstream.
//
// Create copies the files of the repo settings and of .worktreeinclude. It
// does not run the setup command. It records the goal and the link with the
// worktree, and it writes the seed of the plot again, because the seed lists
// the worktrees.
func Create(s *store.Store, o CreateOptions) (*CreateResult, error) {
	n, err := prepare(s, o, true)
	if err != nil {
		return nil, err
	}
	if n.exists != "" {
		return nil, fmt.Errorf("%s: %w", n.exists, store.ErrDuplicate)
	}
	plot, repo, dest := n.plot, n.repo, n.dest

	res := &CreateResult{}
	if n.remoteOn {
		if _, err := git(repo.Path, "fetch", remote); err != nil {
			res.Warnings = append(res.Warnings, fmt.Sprintf("Could not fetch from %s (%v). The worktree starts from the last fetched state.", remote, err))
		}
		n.refreshBranches(o.Name)
	}

	add, base, made, err := n.addArgs(o)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return nil, err
	}
	if _, err := git(repo.Path, add...); err != nil {
		return nil, err
	}

	rec, err := s.AddWorktree(store.Worktree{PlotID: plot.ID, Repo: repo.Path, Name: o.Name, Branch: o.Name, Base: base, Path: dest,
		Goal: o.Goal, Link: n.link})
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
	for _, w := range []string{store.GoalWarning(o.Goal), seed.AfterWorktrees(s, plot.ID)} {
		if w != "" {
			res.Warnings = append(res.Warnings, w)
		}
	}
	return res, nil
}

// addArgs returns the git worktree add command for the new worktree, the
// base to record, and whether the command makes a new branch. A branch that
// exists is used as it is, so a base does not apply to it.
func (n *newWorktree) addArgs(o CreateOptions) (add []string, base string, made bool, err error) {
	switch {
	case n.localBranch:
		if o.Base != "" {
			return nil, "", false, baseDoesNotApply(o.Name)
		}
		return []string{"worktree", "add", n.dest, o.Name}, "", false, nil
	case n.remoteBranch:
		if o.Base != "" {
			return nil, "", false, baseDoesNotApply(o.Name)
		}
		return []string{"worktree", "add", "--track", "-b", o.Name, n.dest, remote + "/" + o.Name}, "", true, nil
	}
	ref, name, err := resolveBase(n.repo.Path, n.remoteOn, o.Base)
	if err != nil {
		return nil, "", false, err
	}
	return []string{"worktree", "add", "--no-track", "-b", o.Name, n.dest, ref}, name, true, nil
}

func baseDoesNotApply(name string) error {
	return fmt.Errorf("the branch %s exists, so --base does not apply: %w", name, store.ErrInvalid)
}

// CheckResult is what [Check] found out about a new worktree.
type CheckResult struct {
	Name string `json:"name"`
	// Folder is the folder name of the worktree, such as "web-fix-login".
	Folder string `json:"folder"`
	// ValidName is false when the name is not a good branch name. NameError
	// then says why.
	ValidName bool   `json:"valid_name"`
	NameError string `json:"name_error,omitempty"`
	// WorktreeExists is true when the plot already has a worktree with the
	// name for the repo, or the folder exists. Create would refuse it.
	WorktreeExists bool `json:"worktree_exists"`
	// BranchExists is true when a local branch or a branch of origin has the
	// name, in the last fetched state. Create uses it as it is.
	BranchExists bool `json:"branch_exists"`
	// DefaultBase is the base of a new branch when no base is given, such as
	// "origin/main". It is empty when the last fetch did not record the
	// default branch of origin (origin/HEAD), or the repo has no origin.
	DefaultBase string `json:"default_base"`
	// Bases are the branches that a new branch can start from: the default
	// base first, then the branches of origin, then the local branches, each
	// with the newest commit first.
	Bases []string `json:"bases"`
	// SeedLine is the line that the seed of the plot gets for the worktree,
	// such as "- web-fix-login: Fix the login form (#57, from origin/main)",
	// with the goal, the link and the base of this check. It is empty when
	// the name is not valid. With no base given and no DefaultBase, it has
	// no base: Create asks the remote for one, and the check does not.
	SeedLine string `json:"seed_line,omitempty"`
}

// Check is a dry run of [Create]. It runs the checks of Create and changes
// nothing. It never asks the remote, so the app can run it as you type: the
// branch checks and the default base read the last fetched state. A name that
// is not a good branch name is a result, not an error. A repo, a link, or a
// base that Create would refuse is an error, as in Create. The exception is a
// base for a branch that exists: Check reports BranchExists and does not check
// the base, though Create refuses any base for that branch.
func Check(s *store.Store, o CreateOptions) (*CheckResult, error) {
	n, err := prepare(s, o, false)
	if err != nil {
		return nil, err
	}
	res := &CheckResult{Name: o.Name, Folder: filepath.Base(n.dest), WorktreeExists: n.exists != "", Bases: []string{}}
	// base is the base that Create would record. A branch that exists has none.
	var base string
	if problem := nameProblem(n.repo.Path, o.Name); problem != "" {
		res.NameError = problem
	} else {
		res.ValidName = true
		res.BranchExists = n.localBranch || n.remoteBranch
		// A given base must work for a new branch, as in Create. Without
		// one, Create asks the remote for its default branch, which a dry
		// run does not. A branch that exists takes no base, so the check is
		// skipped: the app sends its base as you type, and branch_exists
		// tells it that the base does not apply. Create still refuses it.
		if o.Base != "" && !res.BranchExists {
			var err error
			if _, base, _, err = n.addArgs(o); err != nil {
				return nil, err
			}
		}
	}
	if def := fetchedDefaultBranch(n.repo.Path); n.remoteOn && def != "" {
		if _, name, err := resolveBase(n.repo.Path, true, remote+"/"+def); err == nil {
			res.DefaultBase = name
		}
	}
	res.Bases, err = bases(n.repo.Path, n.remoteOn, res.DefaultBase)
	if err != nil {
		return nil, err
	}
	if res.ValidName {
		if o.Base == "" && !res.BranchExists {
			base = res.DefaultBase
		}
		line := seed.WorktreeLine(store.Worktree{Path: n.dest, Base: base, Goal: o.Goal, Link: n.link})
		res.SeedLine = strings.TrimSuffix(line, "\n")
	}
	return res, nil
}

// bases lists the branches that a new branch can start from: first, then
// the branches of origin, then the local branches, each with the newest
// commit first. first is left out when it is empty.
func bases(repo string, remoteOn bool, first string) ([]string, error) {
	patterns := []string{"refs/heads"}
	if remoteOn {
		patterns = append([]string{"refs/remotes/" + remote}, patterns...)
	}
	out, err := git(repo, append([]string{"for-each-ref", "--sort=-committerdate", "--format=%(refname)"}, patterns...)...)
	if err != nil {
		return nil, err
	}
	var remotes, locals []string
	for _, ref := range strings.Split(out, "\n") {
		if b, ok := strings.CutPrefix(ref, "refs/remotes/"); ok && b != remote+"/HEAD" {
			remotes = append(remotes, b)
		} else if b, ok := strings.CutPrefix(ref, "refs/heads/"); ok {
			locals = append(locals, b)
		}
	}
	list := []string{}
	if first != "" {
		list = append(list, first)
	}
	for _, b := range append(remotes, locals...) {
		if b != first {
			list = append(list, b)
		}
	}
	return list, nil
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
	if name := fetchedDefaultBranch(repo); name != "" {
		return name, nil
	}
	return "", fmt.Errorf("cannot find the default branch of %s. Give --base <branch>: %w", remote, store.ErrInvalid)
}

// fetchedDefaultBranch returns the default branch of the remote from the
// last fetch (origin/HEAD), such as "main", or "" when the repo has none.
func fetchedDefaultBranch(repo string) string {
	if out, err := git(repo, "symbolic-ref", "--short", "refs/remotes/"+remote+"/HEAD"); err == nil && out != "" {
		return strings.TrimPrefix(out, remote+"/")
	}
	return ""
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

// Status is the state of a worktree: the local checks, which say what a
// removal would lose, and the ship state from the PR cache.
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

	// Stage is the one stage of the worktree (see [StageOf]).
	Stage Stage `json:"stage"`
	// PR is the pull request of the branch from the last refresh, or nil. It
	// is nil too when the stage comes from the local checks after new work on
	// a merged or closed PR (see [StageInput.UsesPR]), and with the note
	// gh_missing or gh_signed_out (see [PRNote.hidesShipState]).
	PR *github.PR `json:"pr"`
	// PRNote says why the ship state is missing or old.
	PRNote PRNote `json:"pr_note"`
	// PRCheckedAt is when the ship state came from GitHub. It is nil when
	// GitHub never answered for the branch, and with the note gh_missing or
	// gh_signed_out.
	PRCheckedAt *time.Time `json:"pr_checked_at,omitempty"`
	// CompareURL is the GitHub page that compares the branch with its base.
	// It is set only for [StagePushedNoPR].
	CompareURL string `json:"compare_url,omitempty"`

	// localFailed is true when git could not read Changed or Unpushed.
	localFailed bool
}

// Inspect runs the checks on a worktree. It reads the last fetched state and
// does not use the network.
func Inspect(w store.Worktree) Status {
	st := Status{Worktree: w}
	if fi, err := os.Stat(w.Path); err != nil || !fi.IsDir() {
		st.Missing = true
	} else if out, err := git(w.Path, "status", "--porcelain"); err != nil {
		st.Error, st.localFailed = err.Error(), true
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
			st.Error, st.localFailed = err.Error(), true
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

// List inspects the worktrees of a plot, oldest first, and adds the ship state
// from the PR cache. It does not use the network. An empty plotID lists
// every plot.
func List(s *store.Store, plotID string) ([]Status, error) {
	ws, err := s.ListWorktrees(plotID)
	if err != nil {
		return nil, err
	}
	cache, err := s.PRStates()
	if err != nil {
		return nil, err
	}
	out := make([]Status, len(ws))
	for i, w := range ws {
		out[i] = Inspect(w)
		out[i].addPRState(cache[store.PRKey{Repo: w.Repo, Branch: w.Branch}])
	}
	return out, nil
}
