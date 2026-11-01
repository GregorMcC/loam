package run

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/intake"
	"github.com/GregorMcC/loam/core/internal/linear"
	"github.com/GregorMcC/loam/core/internal/sandbox"
	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// NoCIWait is how long the PR of a run can have no checks before Loam takes
// it that no CI runs on it. GitHub can take a moment to start the checks of a
// new head.
var NoCIWait = 3 * time.Minute

// CIRerunWait is how long Loam waits after it runs the failed jobs of a head
// again before it takes a failure on that head as the second one. GitHub can
// show the failed jobs of the first attempt for a moment after the rerun.
var CIRerunWait = time.Minute

// ciLogLines is how many lines of each failed log go back to the session.
const ciLogLines = 60

// pushTimeout limits one git push.
const pushTimeout = 2 * time.Minute

// TickResult is what one tick did: the runs that it moved, and what went
// wrong on the way.
type TickResult struct {
	Runs     []store.Run `json:"runs"`
	Warnings []string    `json:"warnings"`
}

// Tick moves on each run in Shipping. It pushes the branch of the run and
// opens its PR, and then reads CI on the PR. When CI passes, the run is
// Ready, unless the review of the PR requests changes: then the review goes
// back to its session first (see [shipper.passCI]). When CI fails on a head
// for the first time, Loam runs the failed jobs again, and counts no try.
// When the jobs fail again, the run goes back to its session with the failed
// logs, and the failure counts a try (see [shipper.failCI]). Tick also
// watches the PR of each run that is Ready: a merge on GitHub lands the run,
// and a close stops it. It stops a Running run whose session
// ended a turn that Loam has no record of (see [stopIdle]). Then it starts
// the Queued runs, oldest first, while a slot is free and the week's usage
// is under the hold. loam is the loam binary, for the hooks of a new
// session. A tick that waits on GitHub or for a slot changes nothing, so the
// app and a timer can run one as often as they like. Only one tick runs at a
// time: a second one returns at once with nothing.
func Tick(ctx context.Context, s *store.Store, loam string) (TickResult, error) {
	res := TickResult{Runs: []store.Run{}, Warnings: []string{}}
	unlock, ok, err := lockTick(s.Home())
	if err != nil || !ok {
		return res, err
	}
	defer unlock()
	runs, err := s.ListRuns("")
	if err != nil {
		return res, err
	}
	var gh *github.Client
	var ghErr error
	for _, r := range runs {
		watch := r.State == store.RunReady && r.PR != nil
		if r.State != store.RunShipping && !watch {
			continue
		}
		if gh == nil && ghErr == nil {
			gh, ghErr = github.NewClient()
		}
		sh := shipper{s: s, gh: gh, ghErr: ghErr, r: r}
		step := sh.ship
		if watch {
			step = sh.watch
		}
		moved, err := step(ctx)
		if err != nil {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: %v", r.Title, err))
		}
		res.Warnings = append(res.Warnings, sh.warnings...)
		if moved {
			res.Runs = append(res.Runs, sh.r)
		}
	}
	stopped, warnings := stopIdle(ctx, s, runs)
	res.Runs = append(res.Runs, stopped...)
	res.Warnings = append(res.Warnings, warnings...)
	started, warnings := startQueued(ctx, s, loam)
	res.Runs = append(res.Runs, started...)
	res.Warnings = append(res.Warnings, warnings...)
	return res, nil
}

// lockTick takes the tick lock in home. It returns false when another tick
// holds it.
func lockTick(home string) (unlock func(), ok bool, err error) {
	return lockFile(filepath.Join(home, "run-tick.lock"))
}

// lockFile takes an exclusive lock on the file, and reports false when
// another process holds it.
func lockFile(path string) (unlock func(), ok bool, err error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, false, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, false, nil
		}
		return nil, false, err
	}
	return func() { f.Close() }, true, nil
}

// shipper moves one run in Shipping, or watches the PR of one that is Ready.
type shipper struct {
	s        *store.Store
	gh       *github.Client
	ghErr    error
	r        store.Run
	warnings []string
	// noLinearDone keeps the Linear issue where it is when the run lands.
	noLinearDone bool
}

// ship does the next step of the run. It returns true when the run record
// changed. Before it reads CI on the head of the branch, it posts the
// replies to a review that Loam sent back (see [shipper.postReplies]). An
// error leaves the run as it is, for the next tick: GitHub may be out of
// reach, or the store may be busy. Only a worktree that the store does not
// have is gone.
func (sh *shipper) ship(ctx context.Context) (bool, error) {
	r := sh.r
	w, err := sh.s.GetWorktree(r.WorktreeID)
	switch {
	case errors.Is(err, store.ErrNotFound) && r.PR != nil:
		return sh.watchGone(ctx, true)
	case errors.Is(err, store.ErrNotFound):
		return sh.move(store.RunReady, "The worktree is gone, so Loam opens no PR")
	case err != nil:
		return false, err
	}
	repo, ok := worktree.GitHubRepo(w.Repo)
	if !ok {
		return sh.move(store.RunReady, "The repo has no GitHub origin, so Loam opens no PR")
	}
	if errors.Is(sh.ghErr, github.ErrGHMissing) || errors.Is(sh.ghErr, github.ErrSignedOut) {
		return sh.move(store.RunReady, "Loam could not open a PR: "+sh.ghErr.Error())
	}
	if sh.ghErr != nil {
		return false, sh.ghErr
	}
	head, err := branchHead(ctx, r.Folder, w.Branch)
	if err != nil {
		return false, err
	}
	branches, err := sh.gh.Fetch(ctx, repo, []string{w.Branch})
	if err != nil {
		return false, err
	}
	pr := branches[w.Branch].PR
	if moved, ended, err := sh.ended(ctx, pr); ended {
		return moved, err
	}
	if pr != nil && pr.State != "OPEN" {
		pr = nil // an old PR of a branch with the same name
	}
	if pr != nil && (r.PR == nil || r.PR.Number != pr.Number) {
		// You or the session opened the PR: it is the run's PR now.
		return sh.adopt(pr)
	}
	if pr == nil || pr.HeadOID != head {
		return sh.push(ctx, repo, w, head, pr)
	}
	if sh.r.ReviewReplies != nil {
		// The PR shows the fix of a review send-back, or the session made
		// no commit: the reviewer can read the replies with the code.
		if pr, err = sh.postReplies(ctx, repo, w, pr); err != nil {
			return false, err
		}
	}
	return sh.readCI(ctx, repo, pr)
}

// watch lands a Ready run when GitHub has merged its PR, and stops it when
// GitHub has closed its PR. The run goes back to Shipping when the branch has
// commits after the head of the open PR (see [shipper.shipAgain]), when the
// checks of the PR run or fail again on the head of the branch, such as
// after a push by hand, or when the review of the PR requests changes that
// Loam can send back (see [reviewOf]). Then a later tick reads CI, and sends
// the review back when CI passes. A PR head that the branch does not have,
// such as a push from another machine, keeps the run Ready, because Loam
// cannot push it. A land that waits for GitHub, with an auto merge or a
// merge queue, merges the PR as it is, so watch changes nothing while one
// waits. A run that cannot reach GitHub waits with no warning, because it
// needs nothing from a tick. A store that cannot read the worktree is an
// error, not a worktree that is gone.
func (sh *shipper) watch(ctx context.Context) (bool, error) {
	w, err := sh.s.GetWorktree(sh.r.WorktreeID)
	switch {
	case errors.Is(err, store.ErrNotFound):
		return sh.watchGone(ctx, false)
	case err != nil:
		return false, err
	}
	if sh.ghErr != nil {
		return false, nil
	}
	repo, ok := worktree.GitHubRepo(w.Repo)
	if !ok {
		return false, nil
	}
	branches, err := sh.gh.Fetch(ctx, repo, []string{w.Branch})
	if err != nil {
		return false, err
	}
	pr := branches[w.Branch].PR
	if moved, ended, err := sh.ended(ctx, pr); ended || err != nil {
		return moved, err
	}
	if pr == nil || pr.Number != sh.r.PR.Number || w.Land != nil || pr.InMergeQueue {
		return false, nil
	}
	if sh.commitsAfter(ctx, w.Branch, pr.HeadOID) {
		return sh.shipAgain(ctx, w, pr)
	}
	// Shipping would wait for a push that Loam does not make.
	if local, err := branchHead(ctx, sh.r.Folder, w.Branch); err != nil || local != pr.HeadOID {
		return false, nil
	}
	var kind, note string
	switch {
	case ciNotPassed(pr.Checks):
		kind, note = "ship", fmt.Sprintf("The checks of #%d run or failed after it was ready. Loam reads CI again", pr.Number)
	case !reviewOf(sh.r, pr).empty() && sh.r.ReviewTries < store.DefaultMaxReviewTries:
		kind, note = "review", fmt.Sprintf("Changes are requested on #%d after it was ready. Loam sends the review back", pr.Number)
	default:
		return false, nil
	}
	moved, err := sh.move(store.RunShipping, note)
	if !moved || err != nil {
		return moved, err
	}
	return moved, sh.s.AddRunEvent(sh.r.ID, kind, note)
}

// shipAgain pushes the commits of the branch after the head of the run's PR,
// and the run is Shipping again, so a later tick reads CI on the new head.
// The code review of the Ready run runs first, as before each push (see
// [shipper.codeReview]), and a Critical or Major finding sends the run back
// to its session. It pushes even when origin/<branch> is the branch
// head already, because GitHub can have an older head, such as after a force
// push.
func (sh *shipper) shipAgain(ctx context.Context, w store.Worktree, pr *github.PR) (bool, error) {
	head, err := branchHead(ctx, sh.r.Folder, w.Branch)
	if err != nil {
		return false, err
	}
	if ok, moved, err := sh.codeReview(ctx, w, head); !ok || err != nil {
		return moved, err
	}
	note := fmt.Sprintf("The branch has commits after the head of #%d. Loam pushes them, and CI runs again", pr.Number)
	moved, err := sh.move(store.RunShipping, note)
	if !moved || err != nil {
		return moved, err
	}
	if out, err := sh.gitPush(ctx, w.Branch, head); err != nil {
		return sh.move(store.RunStopped, failureNote("git push failed", err, out))
	}
	return moved, sh.s.AddRunEvent(sh.r.ID, "ship", fmt.Sprintf("Pushed the new commits to #%d", pr.Number))
}

// commitsAfter reports whether the branch of the run's worktree has commits
// after head. It reads the branch and not HEAD, because HEAD can be on
// another branch. A head that the worktree does not have, such as a push from
// another machine, is not before the branch: Loam does not push over it.
func (sh *shipper) commitsAfter(ctx context.Context, branch, head string) bool {
	local, err := branchHead(ctx, sh.r.Folder, branch)
	if err != nil || local == head {
		return false
	}
	_, err = gitOut(ctx, sh.r.Folder, "merge-base", "--is-ancestor", head, local)
	return err == nil
}

// ciNotPassed reports whether checks run, wait, or failed, as [shipper.readCI]
// reads them. The checks of a Ready run passed, or it had none.
func ciNotPassed(c github.Checks) bool {
	return c.Failed > 0 || c.Running > 0 || c.Waiting > 0 || c.State == "PENDING" || c.State == "EXPECTED"
}

// watchGone does the step for a run with a PR whose worktree is gone, such as
// after loam worktree land removed it. It reads the PR by its number: a merge
// lands the run, and a close stops it. An open PR leaves the run Ready, and
// the note says to merge it or cancel the run. A run that cannot reach GitHub
// waits, and in a Shipping run (ship is true) gh missing or signed out makes
// it Ready.
func (sh *shipper) watchGone(ctx context.Context, ship bool) (bool, error) {
	pr := sh.r.PR
	repo, ok := github.PRRepo(pr.URL)
	switch {
	case !ok:
		if !ship {
			return false, nil
		}
		return sh.move(store.RunReady, fmt.Sprintf("The worktree is gone, and Loam cannot read #%d", pr.Number))
	case errors.Is(sh.ghErr, github.ErrGHMissing) || errors.Is(sh.ghErr, github.ErrSignedOut):
		if !ship {
			return false, nil
		}
		return sh.move(store.RunReady, "Loam could not read #"+fmt.Sprint(pr.Number)+": "+sh.ghErr.Error())
	case sh.ghErr != nil:
		if !ship {
			return false, nil
		}
		return false, sh.ghErr
	}
	st, err := sh.gh.ViewPR(ctx, repo, pr.Number)
	if err != nil {
		return false, err
	}
	if moved, ended, err := sh.ended(ctx, &github.PR{Number: st.Number, State: st.State}); ended {
		return moved, err
	}
	if !ship {
		return false, nil
	}
	return sh.move(store.RunReady, fmt.Sprintf("The worktree is gone. Merge #%d on GitHub, or cancel the run", pr.Number))
}

// ended lands the run when pr is the run's PR and GitHub has merged it, and
// stops the run when GitHub has closed it. ended is false when the PR is open
// or is not the run's PR.
func (sh *shipper) ended(ctx context.Context, pr *github.PR) (moved, ended bool, err error) {
	if sh.r.PR == nil || pr == nil || pr.Number != sh.r.PR.Number {
		return false, false, nil
	}
	switch pr.State {
	case "MERGED":
		r, moved, warnings, err := landRun(ctx, sh.s, sh.r, fmt.Sprintf("#%d was merged on GitHub", pr.Number), !sh.noLinearDone)
		sh.r, sh.warnings = r, append(sh.warnings, warnings...)
		return moved, true, err
	case "CLOSED":
		moved, err := sh.move(store.RunStopped, fmt.Sprintf("#%d was closed on GitHub", pr.Number))
		return moved, true, err
	}
	return false, false, nil
}

// push puts the head of the run on GitHub, and opens its PR when it has
// none. With a PR, the push is a fix after a failed CI or a send-back. The
// code review of head runs first (see [shipper.codeReview]). Loam saves the
// PR text on the run before it opens the PR, and a later try for the same
// head uses it again, so a PR that GitHub did not open costs no second call
// to Claude.
func (sh *shipper) push(ctx context.Context, repo github.Repo, w store.Worktree, head string, pr *github.PR) (bool, error) {
	if ok, moved, err := sh.codeReview(ctx, w, head); !ok || err != nil {
		return moved, err
	}
	r := sh.r
	pushed, err := pushedHead(ctx, r.Folder, w.Branch)
	if err != nil || pushed != head {
		if out, err := sh.gitPush(ctx, w.Branch, head); err != nil {
			return sh.move(store.RunStopped, failureNote("git push failed", err, out))
		}
		if pr != nil {
			return false, sh.s.AddRunEvent(r.ID, "ship", fmt.Sprintf("Pushed the fix to #%d", pr.Number))
		}
	}
	if pr != nil {
		return false, nil // GitHub does not show the new head yet
	}
	d, err := sh.prDraft(ctx, repo, w, head)
	if d == nil || err != nil {
		return false, err
	}
	opened, err := sh.gh.CreatePR(ctx, repo, github.NewPR{
		Head: w.Branch, Base: worktree.CompareBase(w), Title: d.Title, Body: d.Body,
	})
	if err != nil {
		return false, err
	}
	moved, err := sh.update(func(r *store.Run) {
		r.PR, r.Notes, r.PRDraft = &store.RunPR{Number: opened.Number, URL: opened.URL}, d.Notes, nil
	})
	if err != nil {
		return moved, err
	}
	if err := sh.s.AddRunEvent(r.ID, "ship", fmt.Sprintf("Opened #%d", opened.Number)); err != nil {
		return moved, err
	}
	sh.attachToLinear(ctx, opened)
	return moved, nil
}

// prDraft returns the PR text of the run for the commit head: the draft that
// the run saved, or a new one that it saves now. Only text with Claude's
// notes is saved: Loam's own text, when Claude could not write, is not, so
// the next try asks Claude again. It returns nil when the run moved on while
// Claude wrote the text.
func (sh *shipper) prDraft(ctx context.Context, repo github.Repo, w store.Worktree, head string) (*store.RunPRDraft, error) {
	if d := sh.r.PRDraft; d != nil && d.Head == head {
		return d, nil
	}
	var others []string
	where := ""
	if plot, err := sh.s.GetPlot(sh.r.PlotID); err == nil {
		// A body that names no other repo is still a good body.
		others, _ = groupRepos(sh.s, plot, sh.r)
		where = plot.Where
	}
	title, body, notes := sh.prText(ctx, w, repo, others, where)
	d := &store.RunPRDraft{Head: head, Title: title, Body: body, Notes: notes}
	if notes == nil {
		return d, nil
	}
	moved, err := sh.update(func(r *store.Run) { r.PRDraft = d })
	if !moved || err != nil {
		return nil, err
	}
	return d, nil
}

// adopt makes an open PR of the branch the PR of the run.
func (sh *shipper) adopt(pr *github.PR) (bool, error) {
	moved, err := sh.update(func(r *store.Run) { r.PR, r.PRDraft = &store.RunPR{Number: pr.Number, URL: pr.URL}, nil })
	if err != nil {
		return moved, err
	}
	return moved, sh.s.AddRunEvent(sh.r.ID, "ship", fmt.Sprintf("Found #%d, the open PR of the branch", pr.Number))
}

// readCI reads the checks on the head of the PR.
func (sh *shipper) readCI(ctx context.Context, repo github.Repo, pr *github.PR) (bool, error) {
	c := pr.Checks
	switch {
	case c.Total == 0:
		if sh.sincePush() < NoCIWait {
			return false, nil
		}
		return sh.passCI(ctx, pr, fmt.Sprintf("No CI ran on #%d", pr.Number))
	case c.Failed > 0:
		return sh.failCI(ctx, repo, pr)
	case c.Running > 0 || c.Waiting > 0 || c.State == "PENDING" || c.State == "EXPECTED":
		return false, nil
	}
	return sh.passCI(ctx, pr, fmt.Sprintf("CI passed on #%d: %d of %d checks", pr.Number, c.Passed, c.Total))
}

// sincePush is how long ago Loam last pushed the run or opened its PR.
func (sh *shipper) sincePush() time.Duration { return sh.since("ship") }

// sinceCI is how long ago Loam last recorded a ci event of the run, such as
// the rerun of its failed jobs.
func (sh *shipper) sinceCI() time.Duration { return sh.since("ci") }

// since is how long ago the run got its last event of the kind, or 0 when it
// has none.
func (sh *shipper) since(kind string) time.Duration {
	events, err := sh.s.RunEvents(sh.r.ID)
	if err != nil {
		return 0
	}
	for _, e := range slices.Backward(events) {
		if e.Kind == kind {
			return time.Since(e.At)
		}
	}
	return 0
}

// passCI makes the run Ready with the note, when CI passed or no CI ran on
// pr. When the review of pr requests changes that Loam can send back (see
// [reviewOf]), the review goes back to the session first, as a review try.
// With no review tries left, the run is Ready, and the note says that
// changes are requested.
func (sh *shipper) passCI(ctx context.Context, pr *github.PR, note string) (bool, error) {
	if err := sh.s.AddRunEvent(sh.r.ID, "ci", note); err != nil {
		return false, err
	}
	rv := reviewOf(sh.r, pr)
	switch {
	case rv.empty():
		return sh.move(store.RunReady, note)
	case sh.r.ReviewTries >= store.DefaultMaxReviewTries:
		return sh.move(store.RunReady, fmt.Sprintf("%s. The review tries are used up, and changes are requested on #%d", note, pr.Number))
	}
	return sh.sendReview(ctx, pr, rv, false)
}

// failCI runs the failed jobs of pr again on the first failure of its head
// (see [shipper.rerunCI]), and counts no try. A second failure on that head,
// or a failure that Loam cannot run again, counts a try, and sends the failed
// logs back to the session. On the last try, the run stops. When no slot is
// free, the run waits in Queued with the failed logs, and a later tick sends
// them. A failure on a head whose failure went back to the session already
// means that the session made no commit for it, such as when the failure is
// outside its change (see [ciOutside]): the run stops, with no try, so you
// read the last message of the session and decide.
func (sh *shipper) failCI(ctx context.Context, repo github.Repo, pr *github.PR) (bool, error) {
	r := sh.r
	if r.CISent == pr.HeadOID {
		note := fmt.Sprintf("CI failed again on #%d: %s. The session made no commit for the failure. "+
			"Read its last message, then send the run back or cancel it", pr.Number, strings.Join(checkNames(pr.FailedChecks), ", "))
		if err := sh.s.AddRunEvent(r.ID, "ci", note); err != nil {
			return false, err
		}
		return sh.move(store.RunStopped, note)
	}
	twice := r.CIRerun == pr.HeadOID
	if twice && sh.sinceCI() < CIRerunWait {
		return false, nil // GitHub may not show the rerun yet
	}
	if !twice {
		if moved, rerun, err := sh.rerunCI(ctx, repo, pr); rerun || err != nil {
			return moved, err
		}
	}
	names := strings.Join(checkNames(pr.FailedChecks), ", ")
	failed := fmt.Sprintf("CI failed on #%d", pr.Number)
	if twice {
		failed = fmt.Sprintf("CI failed twice on #%d", pr.Number)
	}
	if err := sh.s.AddRunEvent(r.ID, "ci", failed+": "+names); err != nil {
		return false, err
	}
	if r.Tries+1 >= r.MaxTries {
		return sh.moveTry(store.RunStopped, fmt.Sprintf("%s after %s: %s", failed, count(r.Tries+1, "try"), names))
	}
	prompt := ciPrompt(ctx, sh.gh, repo, r, pr, twice, hasChecks(sh.s, r))
	return sh.resume(ctx, prompt, failed+": "+names, "CI failure", func(r *store.Run) { r.Tries, r.CISent = r.Tries+1, pr.HeadOID })
}

// rerunCI runs the failed jobs of pr again, with one gh run rerun --failed
// for each GitHub Actions run of a failed check, so a flaky job costs no try.
// The run stays in its state, and keeps the head of pr in [store.Run.CIRerun],
// so Loam runs the jobs of a head again at most once. rerun is false when Loam
// ran nothing again: a failed check that is not a job of GitHub Actions
// fails again on the same head, and a rerun that GitHub refuses, such as of a
// run that is gone, is a ci event. Then the failure goes back to the session.
// A rerun that cannot reach GitHub is an error, for the next tick.
func (sh *shipper) rerunCI(ctx context.Context, repo github.Repo, pr *github.PR) (moved, rerun bool, err error) {
	var runs []int64
	for _, c := range pr.FailedChecks {
		if c.RunID == 0 {
			return false, false, nil
		}
		if !slices.Contains(runs, c.RunID) {
			runs = append(runs, c.RunID)
		}
	}
	if len(runs) == 0 {
		return false, false, nil
	}
	names := strings.Join(checkNames(pr.FailedChecks), ", ")
	for _, id := range runs {
		if err := sh.gh.RerunFailed(ctx, repo, id); err != nil {
			if errors.Is(err, github.ErrOffline) || errors.Is(err, github.ErrRateLimited) {
				return false, false, err
			}
			note := fmt.Sprintf("CI failed on #%d: %s. Loam could not run the failed jobs again: %v", pr.Number, names, err)
			return false, false, sh.s.AddRunEvent(sh.r.ID, "ci", note)
		}
	}
	note := fmt.Sprintf("CI failed on #%d: %s. Loam runs the failed jobs again (%s)", pr.Number, names, runList(runs))
	moved, err = sh.update(func(r *store.Run) { r.CIRerun, r.Note = pr.HeadOID, note })
	if !moved || err != nil {
		return moved, true, err
	}
	return moved, true, sh.s.AddRunEvent(sh.r.ID, "ci", note)
}

// checkNames are the names of the checks.
func checkNames(checks []github.Check) []string {
	names := make([]string, len(checks))
	for i, c := range checks {
		names[i] = c.Name
	}
	return names
}

// runList names the GitHub Actions runs, such as "run 9001" or "runs 9001,
// 9002".
func runList(runs []int64) string {
	ids := make([]string, len(runs))
	for i, id := range runs {
		ids[i] = fmt.Sprint(id)
	}
	if len(ids) == 1 {
		return "run " + ids[0]
	}
	return "runs " + strings.Join(ids, ", ")
}

// resume sends the prompt back to the session of the run, and the run is
// Running with the note. addTry counts the try in the same write. When no
// slot is free, the run waits in Queued with the prompt, and a later tick
// sends it. A prompt that does not reach the session stops the run, and its
// note names what (such as "CI failure").
func (sh *shipper) resume(ctx context.Context, prompt, note, what string, addTry func(*store.Run)) (bool, error) {
	from, moved := sh.r.State, false
	r, err := sh.s.TakeSlot(sh.r.ID, &store.RunQueue{Resume: prompt}, func(r *store.Run) error {
		if r.State == from { // you may have changed the run during the tick
			r.State, r.Note, moved = store.RunRunning, note, true
			r.TurnBase = r.Turns // the turn limit counts from the resume
			r.GateTimeouts = 0   // and the gates that ran out of time
			r.BlockedStops = 0   // and the stops that the gate blocked
			addTry(r)
		}
		return nil
	})
	if err != nil {
		return false, err
	}
	sh.r = r
	if !moved || r.State == store.RunQueued {
		return moved, nil // a run that you changed gets no prompt, and a Queued run gets it from a later tick
	}
	if err := send(ctx, sh.s, sh.r, prompt); err != nil {
		note := "Could not send the " + what + " to the session: " + err.Error()
		r, uerr := sh.s.UpdateRun(r.ID, func(r *store.Run) error {
			if r.State == store.RunRunning {
				r.State, r.Note = store.RunStopped, note
			}
			return nil
		})
		if uerr != nil {
			return moved, uerr
		}
		sh.r = r
	}
	return moved, nil
}

// ciTests is in each prompt of a CI failure. The gate does not run the
// checks of CI, so the session can run the tests that failed there to find
// the cause. A failed job can be a Done when check, such as go test ./...,
// so the session runs only the failed tests, not the whole job. A run with
// checks also gets [leaveToGate].
const ciTests = "To find the cause, read the logs above, and run only the tests that failed in CI, such as one test or one package."

// ciOutside is in each prompt of a CI failure. A flaky test that the run did
// not touch can fail CI, and a change to it to make CI pass is outside the
// goal of the run. The session says so instead, and makes no commit. Then CI
// fails again on the same head, and Loam stops the run (see
// [shipper.failCI]), so you read the last message of the session.
const ciOutside = "Do not change a test outside the goal of the run to make CI pass. When the failure is outside your change, say so in your last message, change nothing, and end your turn."

// ciPrompt is the prompt that sends a CI failure back: each failed check,
// with the end of its log. twice is whether the checks failed again after
// Loam ran the failed jobs again. checks is whether the run has checks (see
// [hasChecks]).
func ciPrompt(ctx context.Context, gh *github.Client, repo github.Repo, r store.Run, pr *github.PR, twice, checks bool) string {
	var b strings.Builder
	if twice {
		fmt.Fprintf(&b, "CI failed twice on #%d (try %d of %d): Loam ran the failed jobs again, and they failed again. These checks failed:\n", pr.Number, r.Tries+1, r.MaxTries)
	} else {
		fmt.Fprintf(&b, "CI failed on #%d (try %d of %d). These checks failed:\n", pr.Number, r.Tries+1, r.MaxTries)
	}
	logs := map[int64]string{}
	for _, c := range pr.FailedChecks {
		fmt.Fprintf(&b, "\n## %s\n", c.Name)
		if c.URL != "" {
			fmt.Fprintf(&b, "%s\n", c.URL)
		}
		if c.RunID == 0 {
			continue
		}
		log, seen := logs[c.RunID]
		if !seen {
			var err error
			if log, err = gh.FailedLog(ctx, repo, c.RunID, ciLogLines); err != nil {
				log = "Loam could not read the log: " + err.Error() + "\n"
			}
			logs[c.RunID] = log
		}
		fmt.Fprintf(&b, "\n```\n%s```\n", log)
	}
	fmt.Fprintf(&b, "\nFix the cause, commit the fix, and end your turn. Loam runs the Done when checks again, then pushes the fix to #%d.\n%s\n%s\n%s", pr.Number, ciTests, ciOutside, checksLine(checks, leaveToGate))
	return b.String()
}

// send gives the session of the run a new prompt. The session waits after its
// turn, so Loam stops it first: a resume of a waiting session starts a copy
// of it. The resume passes the settings of the run again (see
// [session.PrepareRunResume]): with no flags, the session would have no
// sandbox and no run hooks. When Loam cannot build them, the session gets no
// prompt.
func send(ctx context.Context, s *store.Store, r store.Run, prompt string) error {
	if missing := sandbox.Available(); missing != nil {
		return fmt.Errorf("the sandbox of the run cannot start: %w", missing)
	}
	loam, err := loamBinary()
	if err != nil {
		return fmt.Errorf("find the loam binary for the run hooks: %w", err)
	}
	model, effort, err := withDefaults(s, r.PlotID, "", "")
	if err != nil {
		return err
	}
	plan, err := session.PrepareRunResume(s, r, prompt, loam, model, effort)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, startTimeout)
	defer cancel()
	// A session that has already stopped makes this fail, which is fine.
	_ = exec.CommandContext(ctx, plan.Claude, "stop", sessionRef(r)).Run()
	cmd := exec.CommandContext(ctx, plan.Claude, plan.Args...)
	cmd.Dir, cmd.Env = plan.Dir, plan.Env
	cmd.WaitDelay = time.Second
	// With ErrWaitDelay, claude exited well, and a child of it kept the output open.
	if out, err := cmd.CombinedOutput(); err != nil && !errors.Is(err, exec.ErrWaitDelay) {
		return errors.New(failureNote("claude --bg --resume failed", err, string(out)))
	}
	return nil
}

// loamBinary returns the path of the running loam binary with links
// resolved, for the hooks of a run session. send runs in loam: in a tick, a
// command, or the MCP server.
func loamBinary() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if r, err := filepath.EvalSymlinks(exe); err == nil {
		exe = r
	}
	return exe, nil
}

// attachToLinear attaches the new PR to the Linear issue of the run, when
// that update to Linear is on, and records what happened as a "linear"
// event.
func (sh *shipper) attachToLinear(ctx context.Context, pr github.OpenedPR) {
	src := sh.r.Source
	if src == nil || src.Kind != intake.Linear {
		return
	}
	if off, warning := linearUpdateOff(sh.s, sh.r, fmt.Sprintf("attach #%d to %s", pr.Number, src.Key),
		func(u store.LinearUpdates) bool { return u.AttachPR }); off {
		if warning != "" {
			sh.warnings = append(sh.warnings, warning)
		}
		return
	}
	detail := fmt.Sprintf("Attached #%d to %s", pr.Number, src.Key)
	c, err := linear.FromKeychain()
	if err == nil {
		err = c.Attach(ctx, src.Key, pr.URL, fmt.Sprintf("PR #%d", pr.Number))
	}
	if err != nil {
		detail = fmt.Sprintf("Could not attach #%d to %s: %v", pr.Number, src.Key, err)
		sh.warnings = append(sh.warnings, detail)
	}
	if err := sh.s.AddRunEvent(sh.r.ID, "linear", detail); err != nil {
		sh.warnings = append(sh.warnings, err.Error())
	}
}

// prBody is the description of the PR of a run: the goal, the Done when
// checks, and the issue. others are the repos of the other runs of its
// group. It names no local path and no Linear URL, because the repo can be
// public.
func prBody(r store.Run, repo github.Repo, others []string) string {
	var b strings.Builder
	b.WriteString(strings.TrimSpace(cmp.Or(r.Goal, r.Title)) + "\n\n## Done when\n\n")
	for _, c := range r.DoneWhen {
		fmt.Fprintf(&b, "- %s: `%s`\n", c.Name, c.Command)
	}
	fmt.Fprintf(&b, "- %s\n", CommittedCheck)
	b.WriteString(prFooter(r, repo, others))
	return b.String()
}

// prFooter is the end of every PR body of Loam: the issue, the other runs of
// the group, the follow-ups, and who opened the PR. Each line follows a blank line.
func prFooter(r store.Run, repo github.Repo, others []string) string {
	var b strings.Builder
	if src := r.Source; src != nil {
		switch src.Kind {
		case intake.Linear:
			// The key only: the workspace can be private, and the repo public.
			// The attachment links the PR on the Linear side.
			fmt.Fprintf(&b, "\nLinear: %s\n", src.Key)
		case intake.GitHub:
			fmt.Fprintf(&b, "\nCloses %s\n", closesRef(src, repo))
		}
	}
	if len(others) > 0 {
		fmt.Fprintf(&b, "\nThe issue also has runs in %s.\n", joinAnd(others))
	}
	b.WriteString(prFollowUps(r, repo))
	b.WriteString("\nLoam opened this PR for a run whose checks passed.\n")
	return b.String()
}

// closesRef is the issue of a GitHub source as a PR body names it: #57 in
// the same repo, else owner/name#57.
func closesRef(src *store.RunSource, repo github.Repo) string {
	i := strings.LastIndex(src.URL, "/issues/")
	if i < 0 {
		return src.URL
	}
	number := src.URL[i+len("/issues/"):]
	if issueRepo, ok := github.ParseRepo(src.URL[:i]); ok && issueRepo != repo {
		return issueRepo.Owner + "/" + issueRepo.Name + "#" + number
	}
	return "#" + number
}

// move puts the run in the state with the note.
func (sh *shipper) move(state store.RunState, note string) (bool, error) {
	return sh.update(func(r *store.Run) { r.State, r.Note = state, note })
}

// moveTry is move with one more try.
func (sh *shipper) moveTry(state store.RunState, note string) (bool, error) {
	return sh.update(func(r *store.Run) { r.State, r.Note, r.Tries = state, note, r.Tries+1 })
}

// update changes the run when it is still in the state that the tick found:
// you may have stopped it while the tick ran.
func (sh *shipper) update(fn func(*store.Run)) (bool, error) {
	moved, from := false, sh.r.State
	r, err := sh.s.UpdateRun(sh.r.ID, func(r *store.Run) error {
		if r.State != from {
			return nil
		}
		fn(r)
		moved = true
		return nil
	})
	if err != nil {
		return false, err
	}
	sh.r = r
	return moved, nil
}

// gitPush pushes the commit head to the branch on origin, from the worktree
// of the run, and returns the output of git. It pushes the commit that the
// code review read, not the branch, so a commit that the branch gets during
// the review does not go with it. Then the branch tracks origin/<branch>, as
// with git push -u. The push has happened when that fails, so the failure is
// a warning, not an error.
func (sh *shipper) gitPush(ctx context.Context, branch, head string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, pushTimeout)
	defer cancel()
	dir := sh.r.Folder
	out, err := exec.CommandContext(ctx, "git", "-C", dir, "push", "origin", head+":refs/heads/"+branch).CombinedOutput()
	if err != nil {
		return string(out), err
	}
	if track, err := exec.CommandContext(ctx, "git", "-C", dir, "branch", "--set-upstream-to=origin/"+branch, branch).CombinedOutput(); err != nil {
		sh.warnings = append(sh.warnings, failureNote(fmt.Sprintf("%s: git could not make %s track origin/%s", sh.r.Title, branch, branch), err, string(track)))
	}
	return string(out), nil
}

// branchHead is the last commit of the branch in the worktree in dir.
func branchHead(ctx context.Context, dir, branch string) (string, error) {
	return gitOut(ctx, dir, "rev-parse", "--verify", "--quiet", "refs/heads/"+branch)
}

// pushedHead is the last commit of the branch that the worktree in dir
// pushed to origin, as git knows it: the ref origin/<branch>.
func pushedHead(ctx context.Context, dir, branch string) (string, error) {
	return gitOut(ctx, dir, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/"+branch)
}

// gitOut runs git in dir and returns its output with no space at the ends.
func gitOut(ctx context.Context, dir string, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...).Output()
	return strings.TrimSpace(string(out)), err
}
