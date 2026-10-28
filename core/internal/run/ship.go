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

	"github.com/GregorMcC/loam/core/internal/claudebin"
	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/intake"
	"github.com/GregorMcC/loam/core/internal/linear"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// NoCIWait is how long the PR of a run can have no checks before Loam takes
// it that no CI runs on it. GitHub can take a moment to start the checks of a
// new head.
var NoCIWait = 3 * time.Minute

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
// Ready. When CI fails, the run goes back to its session with the failed
// logs, and the failure counts a try. Tick also watches the PR of each run
// that is Ready: a merge on GitHub lands the run, and a close stops it. Then
// it starts the Queued runs, oldest first, while a slot is free and the
// week's usage is under the hold. loam is the loam binary, for the hooks of
// a new session. A tick that waits on GitHub or for a slot changes nothing,
// so the app and a timer can run one as often as they like. Only one tick
// runs at a time: a second one returns at once with nothing.
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
// changed. An error leaves the run as it is, for the next tick: GitHub may
// be out of reach.
func (sh *shipper) ship(ctx context.Context) (bool, error) {
	r := sh.r
	w, err := sh.s.GetWorktree(r.WorktreeID)
	if err != nil {
		if r.PR != nil {
			return sh.watchGone(ctx, true)
		}
		return sh.move(store.RunReady, "The worktree is gone, so Loam opens no PR")
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
	head, err := gitOut(ctx, r.Folder, "rev-parse", "HEAD")
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
	return sh.readCI(ctx, repo, pr)
}

// watch lands a Ready run when GitHub has merged its PR, and stops it when
// GitHub has closed its PR. A run that cannot reach GitHub waits with no
// warning, because it needs nothing from a tick.
func (sh *shipper) watch(ctx context.Context) (bool, error) {
	w, err := sh.s.GetWorktree(sh.r.WorktreeID)
	if err != nil {
		return sh.watchGone(ctx, false)
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
	moved, _, err := sh.ended(ctx, branches[w.Branch].PR)
	return moved, err
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
// none. With a PR, the push is a fix after a failed CI. Loam saves the PR
// text on the run before it opens the PR, and a later try for the same head
// uses it again, so a PR that GitHub did not open costs no second call to
// Claude.
func (sh *shipper) push(ctx context.Context, repo github.Repo, w store.Worktree, head string, pr *github.PR) (bool, error) {
	r := sh.r
	pushed, err := gitOut(ctx, r.Folder, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/"+w.Branch)
	if err != nil || pushed != head {
		pctx, cancel := context.WithTimeout(ctx, pushTimeout)
		defer cancel()
		out, err := exec.CommandContext(pctx, "git", "-C", r.Folder, "push", "-u", "origin", w.Branch).CombinedOutput()
		if err != nil {
			return sh.move(store.RunStopped, failureNote("git push failed", err, string(out)))
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
// the run saved, or a new one that it saves now. It returns nil when the run
// moved on while Claude wrote the text.
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
		return sh.passCI(fmt.Sprintf("No CI ran on #%d", pr.Number))
	case c.Failed > 0:
		return sh.failCI(ctx, repo, pr)
	case c.Running > 0 || c.Waiting > 0 || c.State == "PENDING" || c.State == "EXPECTED":
		return false, nil
	}
	return sh.passCI(fmt.Sprintf("CI passed on #%d: %d of %d checks", pr.Number, c.Passed, c.Total))
}

// sincePush is how long ago Loam last pushed the run or opened its PR.
func (sh *shipper) sincePush() time.Duration {
	events, err := sh.s.RunEvents(sh.r.ID)
	if err != nil {
		return 0
	}
	for _, e := range slices.Backward(events) {
		if e.Kind == "ship" {
			return time.Since(e.At)
		}
	}
	return 0
}

func (sh *shipper) passCI(note string) (bool, error) {
	if err := sh.s.AddRunEvent(sh.r.ID, "ci", note); err != nil {
		return false, err
	}
	return sh.move(store.RunReady, note)
}

// failCI counts a try, and sends the failed logs back to the session. On the
// last try, the run stops. When no slot is free, the run waits in Queued with
// the failed logs, and a later tick sends them.
func (sh *shipper) failCI(ctx context.Context, repo github.Repo, pr *github.PR) (bool, error) {
	r := sh.r
	var names []string
	for _, c := range pr.FailedChecks {
		names = append(names, c.Name)
	}
	failed := fmt.Sprintf("CI failed on #%d", pr.Number)
	if err := sh.s.AddRunEvent(r.ID, "ci", failed+": "+strings.Join(names, ", ")); err != nil {
		return false, err
	}
	if r.Tries+1 >= r.MaxTries {
		return sh.moveTry(store.RunStopped, fmt.Sprintf("%s after %s: %s", failed, count(r.Tries+1, "try"), strings.Join(names, ", ")))
	}
	prompt := ciPrompt(ctx, sh.gh, repo, r, pr)
	from, moved := r.State, false
	r, err := sh.s.TakeSlot(r.ID, &store.RunQueue{Resume: prompt}, func(r *store.Run) error {
		if r.State == from { // you may have changed the run during the tick
			r.State, r.Note, r.Tries, moved = store.RunRunning, failed+": "+strings.Join(names, ", "), r.Tries+1, true
			r.TurnBase = r.Turns // the turn limit counts from the resume
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
	if err := send(ctx, sh.r, prompt); err != nil {
		note := "Could not send the CI failure to the session: " + err.Error()
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

// ciPrompt is the prompt that sends a CI failure back: each failed check,
// with the end of its log.
func ciPrompt(ctx context.Context, gh *github.Client, repo github.Repo, r store.Run, pr *github.PR) string {
	var b strings.Builder
	fmt.Fprintf(&b, "CI failed on #%d (try %d of %d). These checks failed:\n", pr.Number, r.Tries+1, r.MaxTries)
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
	fmt.Fprintf(&b, "\nFix the cause, commit the fix, and end your turn. Loam runs the Done when checks again, then pushes the fix to #%d.\n", pr.Number)
	return b.String()
}

// send gives the session of the run a new prompt. The session waits after its
// turn, so Loam stops it first: a resume of a waiting session starts a copy
// of it. With no flags, the resume keeps the options of the session, its
// hooks too.
func send(ctx context.Context, r store.Run, prompt string) error {
	if r.SessionID == "" {
		return errors.New("the run has no session")
	}
	claude, err := claudebin.Find()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, startTimeout)
	defer cancel()
	// A session that has already stopped makes this fail, which is fine.
	exec.CommandContext(ctx, claude, "stop", sessionRef(r)).Run()
	cmd := exec.CommandContext(ctx, claude, "--bg", "--resume", r.SessionID, prompt)
	cmd.Dir = r.Folder
	cmd.WaitDelay = time.Second
	// With ErrWaitDelay, claude exited well, and a child of it kept the output open.
	if out, err := cmd.CombinedOutput(); err != nil && !errors.Is(err, exec.ErrWaitDelay) {
		return errors.New(failureNote("claude --bg --resume failed", err, string(out)))
	}
	return nil
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
// the group, and who opened the PR. Each line follows a blank line.
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

// gitOut runs git in dir and returns its output with no space at the ends.
func gitOut(ctx context.Context, dir string, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...).Output()
	return strings.TrimSpace(string(out)), err
}
