// Package run starts and follows runs. A run is one goal that a background
// Claude Code session (claude --bg) works on in a worktree, until its Done
// when checks pass. Loam's Stop hook is the gate: it runs the checks each
// time the session ends a turn, and sends the failures back as the next try.
//
// Main entry points:
//
//   - [Start] makes or finds the worktree, checks trust and setup, records
//     the run, and starts its background session.
//   - [Stop] stops the background session of a run.
//   - [Hook] answers the hooks of a run session (`loam run hook <id>`).
package run

import (
	"bytes"
	"cmp"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"
	"unicode"

	"github.com/GregorMcC/loam/core/internal/claudebin"
	"github.com/GregorMcC/loam/core/internal/intake"
	"github.com/GregorMcC/loam/core/internal/linear"
	"github.com/GregorMcC/loam/core/internal/sandbox"
	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/wayfinder"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// ErrUntrusted means Claude Code does not trust the folder of the run. A
// background session cannot show the trust prompt.
var ErrUntrusted = errors.New("Claude Code does not trust the folder")

// startTimeout limits claude --bg, which returns when the supervisor has the
// session.
const startTimeout = 2 * time.Minute

// StartOptions says which run to start.
type StartOptions struct {
	PlotID   string
	Title    string
	Goal     string
	DoneWhen []store.Check
	// Repo is the repo of a new worktree: an ID or a path. Empty means the
	// repo of the run that Fixes names, else the repo of the plot that a
	// GitHub issue link belongs to, else the main repo.
	Repo string
	// Worktree is the name of the worktree. Loam uses the worktree when it
	// exists, and makes it when it does not. Empty means a new worktree with
	// a name from the link key and the title.
	Worktree string
	// Base is the branch that a new worktree's branch starts from. Empty
	// means the default branch of origin.
	Base string
	// Link is the link that the work starts from, as for a new worktree.
	Link string
	// Ticket is the file of a ticket of a wayfinder map that the work starts
	// from. A run has a link or a ticket, not both.
	Ticket string
	// Source is the source of a run that no link or ticket gives, such as a
	// recurring run.
	Source   *store.RunSource
	MaxTries int
	// Model and Effort are those of the session. Empty means the run defaults
	// of the plot, then the Claude Code setting.
	Model  string
	Effort string
	// ApproveSetup approves the setup command of the repo when it is new or
	// changed. A run has no terminal to ask on.
	ApproveSetup bool
	// Loam is the absolute path of the loam binary, for the hook command.
	Loam string
	// Fixes is the ID of the landed run of the plot that this run fixes, or
	// empty (see [checkFixes]).
	Fixes string
}

// StartResult is a started run.
type StartResult struct {
	Run      store.Run
	Worktree store.Worktree
	// Warnings are for a person to read.
	Warnings []string
}

// Start makes or finds the worktree of the run, checks that Claude Code
// trusts it, runs the setup command, records the run, and starts its
// background session. A check that fails records nothing. When no slot is
// free, or the week's usage is at the hold, the run waits in Queued, and a
// tick starts it later. A usage that is stale is probed first (see
// [usageForHold]). When claude --bg fails, the run is Stopped, with its
// output as the note.
func Start(ctx context.Context, s *store.Store, o StartOptions) (*StartResult, error) {
	plot, err := s.GetPlot(o.PlotID)
	if err != nil {
		return nil, err
	}
	if plot.Archived {
		return nil, fmt.Errorf("%w: unarchive first with \"loam unarchive %s\"", store.ErrArchived, plot.ID)
	}
	title := strings.TrimSpace(o.Title)
	if title == "" {
		return nil, fmt.Errorf("a run needs a title: %w", store.ErrInvalid)
	}
	if o.Model, o.Effort, err = withDefaults(s, plot.ID, o.Model, o.Effort); err != nil {
		return nil, err
	}
	ticket, err := ticketSource(o.Ticket, o.Link)
	if err != nil {
		return nil, err
	}
	fixed, err := checkFixes(s, plot, o.Fixes)
	if err != nil {
		return nil, err
	}
	if o.Repo == "" {
		o.Repo = fixed
	}
	usageForHold(ctx, s) // before Loam makes anything, so a probe that is cut short leaves nothing
	res := &StartResult{}
	wt, err := prepare(s, plot, o, title, ticket, res)
	if err != nil {
		return nil, err
	}
	r, err := s.AddRun(store.Run{
		PlotID: plot.ID, WorktreeID: wt.ID, Folder: wt.Path, Title: title, Goal: strings.TrimSpace(o.Goal),
		DoneWhen: o.DoneWhen, MaxTries: o.MaxTries, Source: cmp.Or(ticket, o.Source, sourceOf(wt.Link)), Fixes: o.Fixes,
	})
	if err != nil {
		return nil, err
	}
	slotted, err := s.TakeSlot(r.ID, &store.RunQueue{Model: o.Model, Effort: o.Effort}, noChange)
	if err != nil {
		return nil, stopAfter(s, r.ID, err)
	}
	if r = slotted; r.State == store.RunQueued {
		res.Run = r
		return res, nil
	}
	return launch(ctx, s, r, o, res)
}

// checkFixes checks the run that a new run fixes, when id is not empty: it
// must be a landed run of the plot. It returns the path of the repo of that
// run, so the fix goes in the same repo when no --repo names one. The path
// is empty when id is, or when the repo is no longer in the plot.
func checkFixes(s *store.Store, plot store.Plot, id string) (string, error) {
	if id == "" {
		return "", nil
	}
	r, err := s.GetRun(id)
	if err != nil {
		return "", err
	}
	if r.PlotID != plot.ID {
		return "", fmt.Errorf("run %s is in another plot, and a run fixes a run of its own plot: %w", id, store.ErrInvalid)
	}
	if r.State != store.RunLanded {
		return "", fmt.Errorf("run %s is %s, and a run fixes a landed run: %w", id, r.State, store.ErrInvalid)
	}
	return fixedRepo(s, plot, r), nil
}

// fixedRepo is the path of the repo of a run: the repo of its draft, else
// the repo of its worktree, else its folder when that is a repo of the plot.
// A landed run's worktree can be gone, so each step can find nothing.
func fixedRepo(s *store.Store, plot store.Plot, r store.Run) string {
	var arg string
	switch {
	case r.Shape != nil && r.Shape.Repo != "":
		arg = r.Shape.Repo
	case r.WorktreeID != "":
		if wt, err := s.GetWorktree(r.WorktreeID); err == nil {
			arg = wt.Repo
		}
	}
	if arg == "" {
		arg = r.Folder
	}
	repo, err := worktree.FindRepo(plot, arg)
	if err != nil {
		return ""
	}
	return repo.Path
}

// withDefaults checks the effort of a run and fills the model and the effort
// that it leaves empty from the run defaults of the plot. Start and Shape
// use it, so a run from the CLI and a recurring run get the same defaults.
func withDefaults(s *store.Store, plotID, model, effort string) (string, string, error) {
	if err := store.CheckEffort(effort); err != nil {
		return "", "", err
	}
	d, err := s.GetRunDefaults(plotID)
	if err != nil {
		return "", "", err
	}
	return cmp.Or(model, d.Model), cmp.Or(effort, d.Effort), nil
}

// ticketSource returns the source of a run from the file of a ticket of a
// wayfinder map, or nil with no ticket. A run has a link or a ticket, not
// both.
func ticketSource(ticket, link string) (*store.RunSource, error) {
	if ticket == "" {
		return nil, nil
	}
	if link != "" {
		return nil, fmt.Errorf("a run starts from a link or a ticket, not both: %w", store.ErrInvalid)
	}
	t, err := wayfinder.ReadTicket(ticket)
	if err != nil {
		return nil, fmt.Errorf("%s is not a ticket of a map: %v: %w", ticket, err, store.ErrInvalid)
	}
	return &store.RunSource{Kind: intake.Map, Key: t.Key, URL: t.Path}, nil
}

// prepare makes or finds the worktree of a run, checks that Claude Code
// trusts it, and runs the setup command. It records the worktree in res.
func prepare(s *store.Store, plot store.Plot, o StartOptions, title string, ticket *store.RunSource, res *StartResult) (store.Worktree, error) {
	wt, warnings, err := findOrMakeWorktree(s, plot, o, title, ticket)
	if err != nil {
		return store.Worktree{}, err
	}
	res.Worktree = wt
	res.Warnings = append(res.Warnings, warnings...)
	if !claudebin.Trusted(wt.Path) {
		// Claude Code trusts a worktree when it trusts the main checkout.
		return store.Worktree{}, fmt.Errorf("%w %s, and a run cannot answer the trust prompt. Run claude in %s once and choose Yes, then start the run again",
			ErrUntrusted, wt.Path, wt.Repo)
	}
	if err := setUp(s, wt, o.ApproveSetup); err != nil {
		return store.Worktree{}, err
	}
	return wt, nil
}

// launch starts the background session of a recorded run in its folder, and
// moves its Linear issue to In Progress. When claude --bg fails, the run is
// Stopped, with its output as the note. With no sandbox, the run goes back to
// Queued with its model and effort, and a tick starts it later.
func launch(ctx context.Context, s *store.Store, r store.Run, o StartOptions, res *StartResult) (*StartResult, error) {
	if missing := sandbox.Available(); missing != nil {
		queued, err := s.UpdateRun(r.ID, func(r *store.Run) error {
			r.State, r.Note = store.RunQueued, sandboxNote(missing)
			r.Queue = &store.RunQueue{Model: o.Model, Effort: o.Effort}
			return nil
		})
		if err != nil {
			return nil, err
		}
		res.Run = queued
		return res, nil
	}
	rules, err := s.ListRules(r.PlotID)
	if err != nil {
		return nil, stopAfter(s, r.ID, err)
	}
	plan, err := session.PrepareRun(s, r, Prompt(r, rules), o.Loam, o.Model, o.Effort)
	if err != nil {
		return nil, stopAfter(s, r.ID, err)
	}
	parent := ctx
	ctx, cancel := context.WithTimeout(ctx, startTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, plan.Claude, plan.Args...)
	cmd.Dir, cmd.Env = plan.Dir, plan.Env
	cmd.WaitDelay = time.Second
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	runErr := cmd.Run()
	if errors.Is(runErr, exec.ErrWaitDelay) {
		runErr = nil // claude exited well, and a child of it kept the output open
	}
	r, err = s.UpdateRun(r.ID, func(r *store.Run) error {
		switch {
		case ctx.Err() != nil:
			// claude may have handed the session to its supervisor.
			r.State, r.Note = store.RunStartUnknown, "claude --bg did not return in time"
		case runErr != nil:
			r.State, r.Note = store.RunStopped, failureNote("claude --bg failed", runErr, out.String())
		case r.State == store.RunStarting:
			r.State = store.RunRunning
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if r.State != store.RunStopped {
		if warning := startLinearIssue(parent, s, r); warning != "" {
			res.Warnings = append(res.Warnings, warning)
		}
	}
	res.Run = r
	return res, nil
}

// startLinearIssue moves the Linear issue of a run that started to In
// Progress, when that update to Linear is on.
func startLinearIssue(ctx context.Context, s *store.Store, r store.Run) string {
	if r.Source == nil || r.Source.Kind != intake.Linear {
		return ""
	}
	if off, warning := linearUpdateOff(s, r, "move "+r.Source.Key+" to In Progress",
		func(u store.LinearUpdates) bool { return u.InProgress }); off {
		return warning
	}
	return moveLinearIssue(ctx, s, r, "In Progress", "has started or ended", (*linear.Client).Start)
}

// moveLinearIssue moves the Linear issue of the run with move, such as
// [linear.Client.Start] to In Progress, and records what happened as a
// "linear" event of the run. to names the state for a failure, and stays
// says why an issue that move leaves stays. A failure does not change the
// run: it returns a warning for a person to read.
func moveLinearIssue(ctx context.Context, s *store.Store, r store.Run, to, stays string,
	move func(*linear.Client, context.Context, string) (string, error)) string {
	if r.Source == nil || r.Source.Kind != intake.Linear {
		return ""
	}
	key := r.Source.Key
	detail, warning := "", ""
	c, err := linear.FromKeychain()
	var moved string
	if err == nil {
		moved, err = move(c, ctx, key)
	}
	switch {
	case err != nil:
		detail = fmt.Sprintf("Could not move %s to %s: %v", key, to, err)
		warning = detail
	case moved != "":
		detail = fmt.Sprintf("Moved %s to %s", key, moved)
	default:
		detail = fmt.Sprintf("%s %s, so Loam did not move it", key, stays)
	}
	if err := s.AddRunEvent(r.ID, "linear", detail); err != nil {
		return err.Error()
	}
	return warning
}

// stopAfter marks a recorded run Stopped by err, and returns err.
func stopAfter(s *store.Store, id string, err error) error {
	// A failed record still returns err, the cause that the caller needs.
	_, _ = s.UpdateRun(id, func(r *store.Run) error {
		r.State, r.Note = store.RunStopped, err.Error()
		return nil
	})
	return err
}

// findOrMakeWorktree returns the worktree that o names, and makes it when it
// does not exist. A new worktree without a name takes its name from the key
// of the ticket, or of the link, and the title.
func findOrMakeWorktree(s *store.Store, plot store.Plot, o StartOptions, title string, ticket *store.RunSource) (store.Worktree, []string, error) {
	name := o.Worktree
	if name != "" {
		w, err := worktree.Find(s, plot.ID, o.Repo, name)
		if err == nil {
			return w, nil, nil
		}
		if !errors.Is(err, store.ErrNotFound) {
			return store.Worktree{}, nil, err
		}
	}
	repo, err := runRepo(plot, o.Repo, o.Link)
	if err != nil {
		return store.Worktree{}, nil, err
	}
	if name == "" {
		var err error
		key := ""
		if ticket != nil {
			key = ticket.Key
		} else if l, err := worktree.ResolveLink(plot, repo.Path, o.Link); err == nil && l != nil {
			key = l.Key
		}
		if name, err = freeName(s, plot, title, key); err != nil {
			return store.Worktree{}, nil, err
		}
	}
	// A refused setup command makes no worktree, so a second start with
	// --approve-setup gets the same name.
	if err := approveSetup(s, repo.Path, o.ApproveSetup); err != nil {
		return store.Worktree{}, nil, err
	}
	res, err := worktree.Create(s, worktree.CreateOptions{PlotID: plot.ID, Repo: repo.ID, Name: name, Base: o.Base, Goal: title, Link: o.Link})
	if err != nil {
		return store.Worktree{}, nil, err
	}
	return res.Worktree, res.Warnings, nil
}

// runRepo returns the repo of a run: the repo that arg names, else the repo
// of the plot that the link is a GitHub issue of, else the main repo.
func runRepo(plot store.Plot, arg, link string) (store.Repo, error) {
	if arg != "" {
		return worktree.FindRepo(plot, arg)
	}
	if repo, ok := linkRepo(plot, link); ok {
		return repo, nil
	}
	if m := plot.MainRepo(); m != nil {
		return *m, nil
	}
	return store.Repo{}, fmt.Errorf("the plot has no repo, so a run has no worktree. Add a repo with loam repo add: %w", store.ErrInvalid)
}

// freeName returns a worktree name from the key and the title, such as
// eng-523-drag-a-link-to-reorder, with a number added when the plot has a
// worktree of that name.
func freeName(s *store.Store, plot store.Plot, title, key string) (string, error) {
	base := slug(strings.TrimSpace(key + " " + title))
	if base == "" {
		base = "run"
	}
	ws, err := s.ListWorktrees(plot.ID)
	if err != nil {
		return "", err
	}
	taken := map[string]bool{}
	for _, w := range ws {
		taken[w.Name] = true
	}
	name := base
	for n := 2; taken[name]; n++ {
		name = fmt.Sprintf("%s-%d", base, n)
	}
	return name, nil
}

// slugMax is the longest slug. A slug cut short ends at a whole word.
const slugMax = 48

// slug turns text into lowercase words of letters and digits, joined by "-".
func slug(text string) string {
	var words []string
	for _, w := range strings.FieldsFunc(strings.ToLower(text), func(r rune) bool {
		return !(r < unicode.MaxASCII && (unicode.IsLetter(r) || unicode.IsDigit(r)))
	}) {
		if n := len(strings.Join(append(words, w), "-")); n > slugMax && len(words) > 0 {
			break
		}
		words = append(words, w)
	}
	out := strings.Join(words, "-")
	if len(out) > slugMax {
		out = out[:slugMax]
	}
	return out
}

// approveSetup checks that the setup command of the repo is approved. With
// approve, it approves a new or changed command. A repo with no setup command
// needs nothing.
func approveSetup(s *store.Store, repoPath string, approve bool) error {
	set, err := s.RepoSettings(repoPath)
	if err != nil || set.Setup == "" || set.Setup == set.SetupApproved {
		return err
	}
	if !approve {
		return fmt.Errorf("the setup command of %s is new or changed: %s. A run cannot ask, so add --approve-setup to approve it, then start the run again: %w",
			filepath.Base(repoPath), set.Setup, store.ErrInvalid)
	}
	return s.ApproveSetup(repoPath, set.Setup)
}

// setUp runs the setup command of the worktree's repo while setup has not
// succeeded. A command that you have not approved runs only with approve.
func setUp(s *store.Store, w store.Worktree, approve bool) error {
	if w.SetupDone {
		return nil
	}
	if err := approveSetup(s, w.Repo, approve); err != nil {
		return err
	}
	set, err := s.RepoSettings(w.Repo)
	if err != nil || set.Setup == "" {
		return err
	}
	cmd := exec.Command("sh", "-c", set.Setup)
	cmd.Dir = w.Path
	out, err := cmd.CombinedOutput()
	if err != nil {
		return errors.New(failureNote("the setup command failed", err, string(out)))
	}
	return s.MarkWorktreeSetup(w.ID)
}

// sourceOf returns the source of a run from the link of its worktree.
func sourceOf(l *store.WorktreeLink) *store.RunSource {
	if l == nil || l.Key == "" {
		return nil
	}
	kind := "github"
	if strings.Contains(l.Target, "linear.app/") {
		kind = "linear"
	}
	return &store.RunSource{Kind: kind, Key: l.Key, URL: l.Target}
}

// noteTail is how much command output a note keeps: the last lines.
const noteTail = 20

// failureNote is what, the error, and the last lines of the output.
func failureNote(what string, err error, out string) string {
	note := fmt.Sprintf("%s (%v)", what, err)
	if t := strings.TrimSpace(tail(out, noteTail)); t != "" {
		note += ":\n" + t
	}
	return note
}

// Prompt is the first prompt of a run's session: the title, the goal, the
// Done when checks, the rules of the plot, and how the gate works.
func Prompt(r store.Run, rules []store.Rule) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Loam run %s: %s\n", r.ID, r.Title)
	if r.Goal != "" {
		fmt.Fprintf(&b, "\nGoal:\n%s\n", r.Goal)
	}
	if r.Source != nil {
		fmt.Fprintf(&b, "\nIssue: %s (%s)\n", r.Source.Key, r.Source.URL)
	}
	if sh := r.Shape; sh != nil {
		if len(sh.Assumptions) > 0 {
			b.WriteString("\nDecisions about the issue:\n")
			for _, a := range sh.Assumptions {
				fmt.Fprintf(&b, "- %s\n", cmp.Or(a.Answer, a.Text))
			}
		}
		if len(sh.Plan) > 0 {
			b.WriteString("\nA plan from the draft. Change it when the code needs you to:\n")
			for i, step := range sh.Plan {
				fmt.Fprintf(&b, "%d. %s\n", i+1, step)
			}
		}
	}
	checks := slices.Clone(r.DoneWhen)
	for _, rule := range rules {
		checks = append(checks, rule.Check())
	}
	if len(checks) > 0 {
		b.WriteString("\nDone when these checks pass in this folder:\n")
		for _, c := range checks {
			fmt.Fprintf(&b, "- %s: `%s`\n", c.Name, c.Command)
		}
		if len(rules) > 0 {
			b.WriteString("The checks named Rule are rules of the plot: every run must pass them.\n")
		}
		fmt.Fprintf(&b, "\nEach time you end a turn, Loam runs the checks. When a check fails, Loam sends you its output, and you continue. You have %d tries.\n", r.MaxTries)
	} else {
		b.WriteString("\nThe run has no checks. It is done when you end a turn.\n")
	}
	b.WriteString("\nNobody watches this session, so do not ask questions: make a sensible choice and say what you chose in your last message. " +
		"Work only in this worktree. When the work is done, commit it on this branch with a clear message. Do not push and do not open a PR: Loam does that.\n")
	return b.String()
}

// Stop stops the background session of a run and marks the run Cancelled.
// A Shaping run, and a Queued run that never started, have no session, so
// Stop only cancels them. A run that has ended stays as it is. When claude
// stop fails, for example because the session is gone, the run is Cancelled
// anyway and the result has a warning. When the run is the last of its
// group, and another run of the group landed, its Linear issue moves to
// Done.
func Stop(ctx context.Context, s *store.Store, id string) (store.Run, []string, error) {
	r, err := s.GetRun(id)
	if err != nil || r.State.Ended() {
		return r, nil, err
	}
	var warnings []string
	if r.State != store.RunShaping && (r.State != store.RunQueued || r.SessionID != "") {
		if warning := stopSession(ctx, r); warning != "" {
			warnings = append(warnings, warning)
		}
	}
	r, err = s.UpdateRun(id, func(r *store.Run) error {
		r.State, r.Note = store.RunCancelled, "Stopped by you"
		return nil
	})
	if err != nil {
		return r, warnings, err
	}
	if warning := finishLinearIssue(ctx, s, r); warning != "" {
		warnings = append(warnings, warning)
	}
	return r, warnings, nil
}

// stopSession stops the background session of the run. It returns a warning
// when claude stop fails, for example because the session is gone.
func stopSession(ctx context.Context, r store.Run) string {
	claude, err := claudebin.Find()
	if err != nil {
		return "Could not find claude to stop the session: " + err.Error()
	}
	ctx, cancel := context.WithTimeout(ctx, startTimeout)
	defer cancel()
	if out, err := exec.CommandContext(ctx, claude, "stop", sessionRef(r)).CombinedOutput(); err != nil {
		return failureNote("claude stop failed", err, string(out))
	}
	return ""
}

// sessionRef names the background session of a run for claude attach, logs,
// and stop: the short ID, which is the start of the session ID, or else the
// session name.
func sessionRef(r store.Run) string {
	if len(r.SessionID) >= 8 {
		return r.SessionID[:8]
	}
	return session.RunSessionName(r.ID)
}

// AttachCommand is the command that opens the background session of a run
// in a terminal.
func AttachCommand(r store.Run) []string { return []string{"claude", "attach", sessionRef(r)} }
