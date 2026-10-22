package worktree

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/store"
)

// Errors of [Land], [Rerun], and [Update] that callers test with errors.Is.
var (
	// ErrNotReady means a check blocks the land. The error is a
	// *[NotReadyError], which lists the checks that block.
	ErrNotReady = errors.New("the worktree is not ready to land")
	// ErrGHUnavailable means Loam cannot act on GitHub: gh is missing or
	// signed out, or the origin of the repo is not on GitHub.
	ErrGHUnavailable = errors.New("the GitHub CLI (gh) cannot act on the repo")
)

// CheckName names a check of a land.
type CheckName string

// The checks of a land. [LandCheckNames] lists them.
const (
	// CheckChecks is the CI checks of the PR head.
	CheckChecks CheckName = "checks"
	// CheckReview is the review decision of the PR.
	CheckReview CheckName = "review"
	// CheckBehindBase is whether the base branch has commits that the PR does not have.
	CheckBehindBase CheckName = "behind_base"
	// CheckConflicts is whether the PR has conflicts with its base branch.
	CheckConflicts CheckName = "conflicts"
	// CheckGitHub is whether GitHub blocks the merge for a reason that no
	// other check covers: the Blocked stage.
	CheckGitHub CheckName = "github"
	// CheckLocalChanges is the files of the worktree with uncommitted changes.
	CheckLocalChanges CheckName = "local_changes"
	// CheckUnpushedCommits is the commits of the worktree that are not pushed.
	CheckUnpushedCommits CheckName = "unpushed_commits"
)

// LandCheckNames lists the checks of a land, in the order of a land result.
var LandCheckNames = []CheckName{
	CheckChecks, CheckReview, CheckBehindBase, CheckConflicts, CheckGitHub, CheckLocalChanges, CheckUnpushedCommits,
}

// CheckState is the state of one check of a land.
type CheckState string

// The states of the checks. Each check uses some of them (see docs/contract.md).
// [CheckStates] lists them.
const (
	StateNone             CheckState = "none"
	StatePassed           CheckState = "passed"
	StateFailed           CheckState = "failed"
	StateRunning          CheckState = "running"
	StateWaiting          CheckState = "waiting"
	StateApproved         CheckState = "approved"
	StateChangesRequested CheckState = "changes_requested"
	StateRequired         CheckState = "required"
	StateUpToDate         CheckState = "up_to_date"
	StateBehind           CheckState = "behind"
	StateConflicting      CheckState = "conflicting"
	StateChecking         CheckState = "checking"
	StateClear            CheckState = "clear"
	StateBlocked          CheckState = "blocked"
	StateChanged          CheckState = "changed"
	StateUnpushed         CheckState = "unpushed"
	StateUnknown          CheckState = "unknown"
)

// CheckStates lists every state of a check.
var CheckStates = []CheckState{
	StateNone, StatePassed, StateFailed, StateRunning, StateWaiting, StateApproved, StateChangesRequested, StateRequired,
	StateUpToDate, StateBehind, StateConflicting, StateChecking, StateClear, StateBlocked, StateChanged, StateUnpushed, StateUnknown,
}

// LandCheck is one check of a land: its state, and whether it blocks the land.
type LandCheck struct {
	Name   CheckName  `json:"name"`
	State  CheckState `json:"state"`
	Blocks bool       `json:"blocks"`
}

// NotReadyError is the error of a land that a check blocks.
type NotReadyError struct {
	// Checks are the checks that block, in the order of [LandCheckNames].
	Checks []LandCheck
	// reasons say why each check blocks, for a person to read.
	reasons []string
	folder  string
}

func (e *NotReadyError) Error() string {
	return fmt.Sprintf("%s is not ready to land: %s", e.folder, strings.Join(e.reasons, "; "))
}

// Is makes the error match [ErrNotReady].
func (e *NotReadyError) Is(target error) bool { return target == ErrNotReady }

// ErrorDetails is the details of the JSON error: the checks that block.
func (e *NotReadyError) ErrorDetails() any {
	return struct {
		Checks []LandCheck `json:"checks"`
	}{e.Checks}
}

// ghUnavailableError keeps the message of its cause, and matches
// [ErrGHUnavailable] and the cause.
type ghUnavailableError struct{ err error }

func (e ghUnavailableError) Error() string        { return e.err.Error() }
func (e ghUnavailableError) Unwrap() error        { return e.err }
func (e ghUnavailableError) Is(target error) bool { return target == ErrGHUnavailable }

// ghUnavailable wraps an error that means that Loam cannot act on GitHub
// through gh. It returns any other error as it is.
func ghUnavailable(err error) error {
	if errors.Is(err, github.ErrGHMissing) || errors.Is(err, github.ErrSignedOut) {
		return ghUnavailableError{err}
	}
	return err
}

// LandOptions say how to land a worktree.
type LandOptions struct {
	// Method is the merge method. Empty means the default method of the repo.
	Method github.MergeMethod
	// Auto turns on auto merge: GitHub merges the PR when its checks pass.
	Auto bool
	// KeepWorktree keeps the worktree after the merge.
	KeepWorktree bool
	// KeepRemoteBranch keeps the branch on GitHub after the merge.
	KeepRemoteBranch bool
	// DryRun changes nothing. The result is the plan.
	DryRun bool
	// OpenPanes are folders of panes that the caller knows are open. Loam adds
	// the panes of state.json.
	OpenPanes []string
	// Repo picks the repo when two repos have a worktree with the same name.
	Repo string
}

// LandResult says what a land did, or, for a dry run, what it would do.
type LandResult struct {
	// Worktree is the worktree with the land that it records after the land.
	Worktree store.Worktree `json:"worktree"`
	// PR is the PR as the refresh before the merge found it.
	PR    *github.PR `json:"pr"`
	Stage Stage      `json:"stage"`
	// Changed and Unpushed are the local checks of the worktree.
	Changed  int `json:"changed"`
	Unpushed int `json:"unpushed"`
	// Methods are the merge methods that the repo allows, and DefaultMethod
	// is the method that GitHub offers first. Both are empty for a PR that
	// is merged.
	Methods       []github.MergeMethod `json:"methods"`
	DefaultMethod github.MergeMethod   `json:"default_method"`
	// Method is the merge method of the land. It is empty with a merge
	// queue, which merges with its own method, and for a PR that is merged.
	Method github.MergeMethod `json:"method"`
	// MergeQueue is true when the base branch has a merge queue. The land
	// adds the PR to the queue.
	MergeQueue bool `json:"merge_queue"`
	Auto       bool `json:"auto"`
	// Checks are the checks in the order of [LandCheckNames]. They are empty
	// for a PR that is merged.
	Checks []LandCheck `json:"checks"`
	// Ready is true when no check blocks.
	Ready  bool `json:"ready"`
	DryRun bool `json:"dry_run"`
	// Merged is true when GitHub says that the PR is merged.
	Merged bool `json:"merged"`
	// MergeLater is true when GitHub merges later: an auto merge, or a merge
	// queue. Loam records the land on the worktree. It is also true after a
	// merge that Loam cannot see yet (see MergeNote).
	MergeLater bool `json:"merge_later"`
	// MergeNote says why Loam does not see the merge yet.
	MergeNote string `json:"merge_note,omitempty"`
	// RemoteBranchDeleted is true when the branch is no longer on GitHub.
	RemoteBranchDeleted bool   `json:"remote_branch_deleted"`
	RemoteBranchNote    string `json:"remote_branch_note,omitempty"`
	// WorktreeRemoved, BranchDeleted, and BranchNote are as in [RemoveResult].
	WorktreeRemoved bool   `json:"worktree_removed"`
	WorktreeNote    string `json:"worktree_note,omitempty"`
	BranchDeleted   bool   `json:"branch_deleted"`
	BranchNote      string `json:"branch_note,omitempty"`
}

// Land merges the PR of a worktree of a plot on GitHub, then deletes the
// branch on GitHub and removes the worktree. The argument is as in [Find].
//
// Land refreshes the PR first, and stops when GitHub does not answer: Loam
// never acts on an old state. It reads the merge methods that the repo allows,
// its default method, and the merge queue. Then it runs the checks, and fails
// with [ErrNotReady] when a check blocks. The merge names the PR head that
// Land checked, so GitHub refuses it when the PR has a new commit.
//
// With an auto merge or a merge queue, GitHub merges later. Land records its
// options on the worktree and keeps the worktree. For a PR that is merged,
// Land skips the merge and does what comes after it.
//
// It fails with [ErrGHUnavailable] when gh is missing or signed out, or the
// origin of the repo is not on GitHub.
func Land(ctx context.Context, s *store.Store, plotID, arg string, o LandOptions) (*LandResult, error) {
	if o.Method != "" && !slices.Contains(github.MergeMethods, o.Method) {
		return nil, fmt.Errorf("%q is not a merge method. Use %s: %w", o.Method, joinMethods(github.MergeMethods), store.ErrInvalid)
	}
	w, err := Find(s, plotID, o.Repo, arg)
	if err != nil {
		return nil, err
	}
	t, err := openTarget(ctx, s, w)
	if err != nil {
		return nil, err
	}
	res := &LandResult{Worktree: w, PR: t.pr, Stage: t.stage, Methods: []github.MergeMethod{}, Checks: []LandCheck{},
		Auto: o.Auto, DryRun: o.DryRun}
	switch t.pr.State {
	case "MERGED":
		res.Ready, res.Merged = true, true
		if o.DryRun {
			return res, nil
		}
		if !o.KeepWorktree {
			if err := refuseOpenPanes(w, o.OpenPanes); err != nil {
				return nil, err
			}
		}
		if err := res.tidy(ctx, s, t, o); err != nil {
			return nil, err
		}
		return res, nil
	case "CLOSED":
		return nil, fmt.Errorf("PR #%d of %s is closed without a merge. Reopen it on GitHub to land it", t.pr.Number, w.Branch)
	}
	switch {
	case t.pr.InMergeQueue:
		return nil, fmt.Errorf("PR #%d is in the merge queue already. GitHub merges it from the queue", t.pr.Number)
	case !oidPattern.MatchString(t.pr.HeadOID):
		return nil, fmt.Errorf("GitHub gave no head commit for PR #%d, and Loam merges only the commit that it checked", t.pr.Number)
	}

	settings, err := t.client.MergeSettings(ctx, t.repo, t.pr.Number)
	if err != nil {
		return nil, ghUnavailable(err)
	}
	res.Methods, res.DefaultMethod, res.MergeQueue = settings.Methods, settings.Default, settings.Queue
	switch {
	case settings.Queue && o.Method != "":
		return nil, fmt.Errorf("the base branch %s has a merge queue, which picks the merge method. Run again with no --method: %w", t.pr.Base, store.ErrInvalid)
	case settings.Queue:
	case o.Method == "":
		res.Method = settings.Default
	case !slices.Contains(settings.Methods, o.Method):
		return nil, fmt.Errorf("the repo does not allow a %s merge. Use %s: %w", o.Method, joinMethods(settings.Methods), store.ErrInvalid)
	default:
		res.Method = o.Method
	}

	st := Inspect(w)
	res.Changed, res.Unpushed = st.Changed, st.Unpushed
	direct := !o.Auto && !settings.Queue
	res.Checks = landChecks(t.pr, t.stage, st, direct)
	res.Ready = !slices.ContainsFunc(res.Checks, func(c LandCheck) bool { return c.Blocks })
	if o.DryRun {
		return res, nil
	}
	if !res.Ready {
		return nil, notReady(w, t.pr, st, res.Checks)
	}
	if direct && !o.KeepWorktree {
		if err := refuseOpenPanes(w, o.OpenPanes); err != nil {
			return nil, err
		}
	}

	err = t.client.Merge(ctx, t.repo, t.pr.Number, github.MergeOptions{Method: res.Method, Auto: o.Auto, HeadOID: t.pr.HeadOID})
	switch {
	case errors.Is(err, github.ErrOffline) || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded):
		// gh stopped before GitHub answered. A land again checks first.
		return nil, fmt.Errorf("gh stopped before GitHub answered, so GitHub may have the land of PR #%d (%w). Run loam worktree land again to finish it", t.pr.Number, err)
	case err != nil:
		return nil, ghUnavailable(err)
	}
	// GitHub has the merge, the queue entry, or the auto merge. Errors from
	// here on are notes: the land cannot go back.
	after, err := openTarget(ctx, s, w)
	switch {
	case err != nil:
		res.MergeNote = fmt.Sprintf("GitHub took the land of PR #%d, but Loam could not read the PR again (%v). Run loam worktree land again to finish it.", t.pr.Number, err)
	case after.pr.State == "MERGED":
		res.Merged = true
		if err := res.tidy(ctx, s, after, o); err != nil {
			return nil, err
		}
		return res, nil
	case direct:
		// gh pr merge ends after GitHub merges the PR, so only the answer of
		// GitHub is late.
		res.MergeNote = fmt.Sprintf("GitHub merged PR #%d, but the PR does not show the merge yet. Run loam worktree land again to finish it.", t.pr.Number)
	}
	res.MergeLater = true
	pending := &store.PendingLand{PR: t.pr.Number, Method: string(res.Method), Auto: o.Auto, MergeQueue: settings.Queue,
		KeepWorktree: o.KeepWorktree, KeepRemoteBranch: o.KeepRemoteBranch}
	if err := s.SetPendingLand(w.ID, pending); err != nil {
		return nil, err
	}
	res.Worktree.Land = pending
	return res, nil
}

// tidy does what comes after a merge: it deletes the branch on GitHub and
// removes the worktree, unless the options keep them. A step that fails is a
// note. When the worktree stays, tidy clears the land that it records: the
// land waits for GitHub no more.
func (res *LandResult) tidy(ctx context.Context, s *store.Store, t *target, o LandOptions) error {
	if !o.KeepRemoteBranch {
		err := t.client.DeleteBranch(ctx, t.repo, t.pr.Head, t.pr.HeadOID)
		switch {
		case err == nil:
			res.RemoteBranchDeleted = true
		case errors.Is(err, github.ErrBranchMoved):
			res.RemoteBranchNote = fmt.Sprintf("Kept the branch %s on GitHub: it has commits after the head of PR #%d.", t.pr.Head, t.pr.Number)
		default:
			res.RemoteBranchNote = fmt.Sprintf("Kept the branch %s on GitHub: %v", t.pr.Head, err)
		}
	}
	if !o.KeepWorktree {
		rm, err := Remove(s, t.w.PlotID, t.w.ID, RemoveOptions{OpenPanes: o.OpenPanes})
		var unsafe *unsafeError
		switch {
		case err == nil:
			res.WorktreeRemoved, res.BranchDeleted, res.BranchNote = true, rm.BranchDeleted, rm.BranchNote
			return nil
		case errors.As(err, &unsafe):
			// The note of Remove names --force, which land does not have.
			res.WorktreeNote = fmt.Sprintf("Kept the worktree %s: it has %s. Save the work, then remove the worktree with loam worktree rm.",
				unsafe.folder, unsafe.work())
		default:
			res.WorktreeNote = fmt.Sprintf("Kept the worktree %s: %v", filepath.Base(t.w.Path), err)
		}
	}
	if t.w.Land == nil {
		return nil
	}
	res.Worktree.Land = nil
	return s.SetPendingLand(t.w.ID, nil)
}

// landChecks runs the checks of a land on an open PR with its stage, and on
// the local checks of its worktree. They use the stage rule (see [prStage]).
// While GitHub checks whether the PR can merge, the rule keeps the last stage
// that needs that check, so Conflicts, Behind base, and Blocked come from the
// stage too. direct is true for a merge now: no auto merge and no merge queue.
func landChecks(pr *github.PR, stage Stage, st Status, direct bool) []LandCheck {
	checks := checksState(pr)
	review := map[string]CheckState{"APPROVED": StateApproved, "CHANGES_REQUESTED": StateChangesRequested, "REVIEW_REQUIRED": StateRequired}[pr.ReviewDecision]
	if review == "" {
		review = StateNone
	}
	behindBlocks := behindRequired(pr) || stage == StageBehindBase
	behind := StateUpToDate
	if pr.BehindBase > 0 || behindBlocks {
		behind = StateBehind
	}
	conflicts := StateNone
	switch {
	case hasConflicts(pr) || stage == StageConflicts:
		conflicts = StateConflicting
	case !mergeChecked(pr):
		conflicts = StateChecking
	}
	gh := StateClear
	switch {
	case stage == StageBlocked:
		gh = StateBlocked
	case !mergeChecked(pr):
		gh = StateChecking
	}
	changed, unpushed := StateNone, StateNone
	switch {
	case st.localFailed:
		changed, unpushed = StateUnknown, StateUnknown
	default:
		if st.Changed > 0 {
			changed = StateChanged
		}
		if st.Unpushed > 0 {
			unpushed = StateUnpushed
		}
	}
	return []LandCheck{
		{Name: CheckChecks, State: checks, Blocks: checks == StateFailed},
		{Name: CheckReview, State: review, Blocks: review == StateChangesRequested},
		// Behind base blocks only when the base branch needs the PR up to date.
		{Name: CheckBehindBase, State: behind, Blocks: behindBlocks},
		{Name: CheckConflicts, State: conflicts, Blocks: conflicts == StateConflicting},
		// An auto merge and a merge queue wait until GitHub can merge.
		{Name: CheckGitHub, State: gh, Blocks: gh == StateBlocked && direct},
		{Name: CheckLocalChanges, State: changed, Blocks: changed != StateNone},
		{Name: CheckUnpushedCommits, State: unpushed, Blocks: unpushed != StateNone},
	}
}

// checksState returns the state of the checks of a PR. A failed check
// counts as the stage rule counts it (see [checksFailed]).
func checksState(pr *github.PR) CheckState {
	switch {
	case checksFailed(pr):
		return StateFailed
	case pr.Checks.Waiting > 0:
		return StateWaiting
	case checksRunning(pr):
		return StateRunning
	case pr.Checks.Total > 0:
		return StatePassed
	}
	return StateNone
}

// notReady returns the error of a land that the checks block.
func notReady(w store.Worktree, pr *github.PR, st Status, checks []LandCheck) error {
	e := &NotReadyError{folder: filepath.Base(w.Path)}
	for _, c := range checks {
		if !c.Blocks {
			continue
		}
		e.Checks = append(e.Checks, c)
		e.reasons = append(e.reasons, blockReason(c, pr, st))
	}
	return e
}

// blockReason says why a check blocks a land.
func blockReason(c LandCheck, pr *github.PR, st Status) string {
	switch c.Name {
	case CheckChecks:
		return "a check failed. Run loam worktree rerun to run the failed checks again"
	case CheckReview:
		return "a reviewer asked for changes"
	case CheckBehindBase:
		return fmt.Sprintf("the branch is behind %s, and %s needs it up to date. Run loam worktree update", pr.Base, pr.Base)
	case CheckConflicts:
		return "the PR has conflicts with " + pr.Base
	case CheckGitHub:
		return "GitHub blocks the merge. Open the PR on GitHub to see why, or land with --auto"
	case CheckLocalChanges:
		if c.State == StateUnknown {
			return "git could not read the local changes: " + st.Error
		}
		return fmt.Sprintf("%d file(s) have uncommitted changes", st.Changed)
	case CheckUnpushedCommits:
		if c.State == StateUnknown {
			return "git could not count the commits that are not pushed: " + st.Error
		}
		return fmt.Sprintf("%d commit(s) are not pushed", st.Unpushed)
	}
	return string(c.Name)
}

// refuseOpenPanes fails with [ErrPanesOpen] while a pane is open in the
// worktree, which a land removes.
func refuseOpenPanes(w store.Worktree, extra []string) error {
	n, err := panesIn(w, extra)
	if err != nil {
		return err
	}
	if n > 0 {
		return fmt.Errorf("%d pane(s) are open in %s. Close them, or land with --keep-worktree: %w", n, filepath.Base(w.Path), ErrPanesOpen)
	}
	return nil
}

func joinMethods(ms []github.MergeMethod) string {
	names := make([]string, len(ms))
	for i, m := range ms {
		names[i] = string(m)
	}
	return strings.Join(names, ", ")
}

// target is a worktree with its PR, fresh from GitHub, and what Loam needs
// to act on the PR.
type target struct {
	w      store.Worktree
	pr     *github.PR
	stage  Stage
	client *github.Client
	repo   github.Repo
}

// openTarget refreshes the PR of the worktree, and returns it from the PR
// cache. It fails when the refresh gets no answer from GitHub, and when the
// branch has no PR.
func openTarget(ctx context.Context, s *store.Store, w store.Worktree) (*target, error) {
	if fi, err := os.Stat(w.Path); err != nil || !fi.IsDir() {
		return nil, fmt.Errorf("the folder of %s is gone. Remove the worktree with loam worktree rm", filepath.Base(w.Path))
	}
	if err := RefreshPRs(ctx, s, []store.Worktree{w}); err != nil {
		return nil, err
	}
	cache, err := s.PRStates()
	if err != nil {
		return nil, err
	}
	row := cache[store.PRKey{Repo: w.Repo, Branch: w.Branch}]
	if row.Note != "" {
		return nil, noteError(PRNote(row.Note), w.Repo)
	}
	client, err := github.NewClient()
	if err != nil {
		return nil, ghUnavailable(err)
	}
	repo, ok := githubRepo(w.Repo)
	if !ok {
		return nil, noteError(NoteNoGitHubRemote, w.Repo)
	}
	c := decodeCached(row)
	if c.PR == nil {
		return nil, fmt.Errorf("the branch %s has no PR on GitHub: %w", w.Branch, store.ErrNotFound)
	}
	return &target{w: w, pr: c.PR, stage: c.Stage, client: client, repo: repo}, nil
}

// noteError is the error of a refresh that ended with the note.
func noteError(note PRNote, repo string) error {
	switch note {
	case NoteGHMissing:
		return ghUnavailableError{github.ErrGHMissing}
	case NoteGHSignedOut:
		return ghUnavailableError{github.ErrSignedOut}
	case NoteNoGitHubRemote:
		return ghUnavailableError{fmt.Errorf("the origin of %s is not on GitHub", repo)}
	case NoteNoAccess:
		return github.ErrNoAccess
	case NoteRateLimited:
		return github.ErrRateLimited
	}
	return github.ErrOffline
}

// openPR returns the target of a worktree of a plot with an open PR.
func openPR(ctx context.Context, s *store.Store, plotID, repoArg, arg string) (*target, error) {
	w, err := Find(s, plotID, repoArg, arg)
	if err != nil {
		return nil, err
	}
	t, err := openTarget(ctx, s, w)
	if err != nil {
		return nil, err
	}
	if t.pr.State != "OPEN" {
		return nil, fmt.Errorf("PR #%d of %s is %s. Only an open PR can change", t.pr.Number, w.Branch, strings.ToLower(t.pr.State))
	}
	return t, nil
}

// RerunResult says which runs a rerun started again.
type RerunResult struct {
	Worktree store.Worktree `json:"worktree"`
	PR       *github.PR     `json:"pr"`
	// Runs are the GitHub Actions runs whose failed jobs run again.
	Runs []int64 `json:"runs"`
	// SkippedChecks are the failed checks that are not jobs of GitHub
	// Actions. Loam cannot run them again.
	SkippedChecks []string `json:"skipped_checks"`
}

// Rerun runs the failed jobs of the PR of a worktree again: one gh run rerun
// --failed for each GitHub Actions run with a failed check. It refreshes the
// PR first. The PR must be open.
func Rerun(ctx context.Context, s *store.Store, plotID, repoArg, arg string) (*RerunResult, error) {
	t, err := openPR(ctx, s, plotID, repoArg, arg)
	if err != nil {
		return nil, err
	}
	res := &RerunResult{Worktree: t.w, PR: t.pr, Runs: []int64{}, SkippedChecks: []string{}}
	var runs []int64
	for _, c := range t.pr.FailedChecks {
		switch {
		case c.RunID == 0:
			res.SkippedChecks = append(res.SkippedChecks, c.Name)
		case !slices.Contains(runs, c.RunID):
			runs = append(runs, c.RunID)
		}
	}
	for i, id := range runs {
		if err := t.client.RerunFailed(ctx, t.repo, id); err != nil {
			return nil, fmt.Errorf("started %d of %d runs again: %w", i, len(runs), ghUnavailable(err))
		}
		res.Runs = append(res.Runs, id)
	}
	return res, nil
}

// UpdateResult says what an update did.
type UpdateResult struct {
	Worktree store.Worktree `json:"worktree"`
	PR       *github.PR     `json:"pr"`
	// Fetched is true when the local repo has the new PR head.
	Fetched bool `json:"fetched"`
	// FetchNote says why the fetch failed. GitHub has the update.
	FetchNote string `json:"fetch_note,omitempty"`
}

// Update brings the PR of a worktree up to date with its base branch on
// GitHub (gh pr update-branch). Then it fetches the branch, so the local repo
// has the new PR head, and the stage rule can see that the worktree is in
// the PR (see [StageInput.HeadInPR]). It refreshes the PR first. The PR must
// be open. Update does not change the branch of the worktree.
func Update(ctx context.Context, s *store.Store, plotID, repoArg, arg string) (*UpdateResult, error) {
	t, err := openPR(ctx, s, plotID, repoArg, arg)
	if err != nil {
		return nil, err
	}
	if err := t.client.UpdateBranch(ctx, t.repo, t.pr.Number); err != nil {
		return nil, ghUnavailable(err)
	}
	res := &UpdateResult{Worktree: t.w, PR: t.pr}
	b := t.w.Branch
	if _, err := git(t.w.Repo, "fetch", remote, "+refs/heads/"+b+":refs/remotes/"+remote+"/"+b); err != nil {
		res.FetchNote = fmt.Sprintf("GitHub updated PR #%d, but Loam could not fetch %s (%v). Run git fetch.", t.pr.Number, b, err)
	} else {
		res.Fetched = true
	}
	return res, nil
}
