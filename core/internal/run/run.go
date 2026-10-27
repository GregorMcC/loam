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
	"context"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"github.com/GregorMcC/loam/core/internal/claudebin"
	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
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
	// main repo.
	Repo string
	// Worktree is the name of the worktree. Loam uses the worktree when it
	// exists, and makes it when it does not. Empty means a new worktree with
	// a name from the link key and the title.
	Worktree string
	// Link is the link that the work starts from, as for a new worktree.
	Link     string
	MaxTries int
	Model    string
	// ApproveSetup approves the setup command of the repo when it is new or
	// changed. A run has no terminal to ask on.
	ApproveSetup bool
	// Loam is the absolute path of the loam binary, for the hook command.
	Loam string
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
// background session. A check that fails records nothing. When claude --bg
// fails, the run is Stopped, with its output as the note.
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
	res := &StartResult{}

	wt, warnings, err := findOrMakeWorktree(s, plot, o, title)
	if err != nil {
		return nil, err
	}
	res.Worktree = wt
	res.Warnings = append(res.Warnings, warnings...)

	if !claudebin.Trusted(wt.Path) {
		root := filepath.Join(s.Home(), "worktrees")
		return nil, fmt.Errorf("%w %s, and a run cannot answer the trust prompt. Run claude in %s once and choose Yes, then start the run again",
			ErrUntrusted, wt.Path, root)
	}
	if err := setUp(s, wt, o.ApproveSetup); err != nil {
		return nil, err
	}

	r, err := s.AddRun(store.Run{
		PlotID: plot.ID, WorktreeID: wt.ID, Folder: wt.Path, Title: title, Goal: strings.TrimSpace(o.Goal),
		DoneWhen: o.DoneWhen, MaxTries: o.MaxTries, Source: sourceOf(wt.Link),
	})
	if err != nil {
		return nil, err
	}
	plan, err := session.PrepareRun(s, r, Prompt(r), o.Loam, o.Model)
	if err != nil {
		return nil, stopAfter(s, r.ID, err)
	}
	ctx, cancel := context.WithTimeout(ctx, startTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, plan.Claude, plan.Args...)
	cmd.Dir, cmd.Env = plan.Dir, plan.Env
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	runErr := cmd.Run()
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
	res.Run = r
	return res, nil
}

// stopAfter marks a recorded run Stopped by err, and returns err.
func stopAfter(s *store.Store, id string, err error) error {
	s.UpdateRun(id, func(r *store.Run) error {
		r.State, r.Note = store.RunStopped, err.Error()
		return nil
	})
	return err
}

// findOrMakeWorktree returns the worktree that o names, and makes it when it
// does not exist.
func findOrMakeWorktree(s *store.Store, plot store.Plot, o StartOptions, title string) (store.Worktree, []string, error) {
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
	var repo store.Repo
	if o.Repo != "" {
		r, err := worktree.FindRepo(plot, o.Repo)
		if err != nil {
			return store.Worktree{}, nil, err
		}
		repo = r
	} else if m := plot.MainRepo(); m != nil {
		repo = *m
	} else {
		return store.Worktree{}, nil, fmt.Errorf("the plot has no repo, so a run has no worktree. Add a repo with loam repo add: %w", store.ErrInvalid)
	}
	if name == "" {
		var err error
		if name, err = freeName(s, plot, repo.Path, title, o.Link); err != nil {
			return store.Worktree{}, nil, err
		}
	}
	res, err := worktree.Create(s, worktree.CreateOptions{PlotID: plot.ID, Repo: repo.ID, Name: name, Goal: title, Link: o.Link})
	if err != nil {
		return store.Worktree{}, nil, err
	}
	return res.Worktree, res.Warnings, nil
}

// freeName returns a worktree name from the key of the link and the title,
// such as eng-523-drag-a-link-to-reorder, with a number added when the plot
// has a worktree of that name.
func freeName(s *store.Store, plot store.Plot, repoPath, title, link string) (string, error) {
	base := slug(title)
	if link != "" {
		if l, err := worktree.ResolveLink(plot, repoPath, link); err == nil && l != nil && l.Key != "" {
			base = slug(l.Key + " " + title)
		}
	}
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

// setUp runs the setup command of the worktree's repo while setup has not
// succeeded. A command that you have not approved runs only with approve.
func setUp(s *store.Store, w store.Worktree, approve bool) error {
	if w.SetupDone {
		return nil
	}
	set, err := s.RepoSettings(w.Repo)
	if err != nil || set.Setup == "" {
		return err
	}
	if set.Setup != set.SetupApproved {
		if !approve {
			return fmt.Errorf("the setup command of %s is new or changed: %s. A run cannot ask, so add --approve-setup to approve it, then start the run again: %w",
				filepath.Base(w.Repo), set.Setup, store.ErrInvalid)
		}
		if err := s.ApproveSetup(w.Repo, set.Setup); err != nil {
			return err
		}
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
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) > noteTail {
		lines = lines[len(lines)-noteTail:]
	}
	note := fmt.Sprintf("%s (%v)", what, err)
	if tail := strings.TrimSpace(strings.Join(lines, "\n")); tail != "" {
		note += ":\n" + tail
	}
	return note
}

// Prompt is the first prompt of a run's session: the title, the goal, the
// Done when checks, and how the gate works.
func Prompt(r store.Run) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Loam run %s: %s\n", r.ID, r.Title)
	if r.Goal != "" {
		fmt.Fprintf(&b, "\nGoal:\n%s\n", r.Goal)
	}
	if r.Source != nil {
		fmt.Fprintf(&b, "\nIssue: %s (%s)\n", r.Source.Key, r.Source.URL)
	}
	if len(r.DoneWhen) > 0 {
		b.WriteString("\nDone when these checks pass in this folder:\n")
		for _, c := range r.DoneWhen {
			fmt.Fprintf(&b, "- %s: `%s`\n", c.Name, c.Command)
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
// A run that has ended stays as it is. When claude stop fails, for example
// because the session is gone, the run is Cancelled anyway and the result
// has a warning.
func Stop(ctx context.Context, s *store.Store, id string) (store.Run, []string, error) {
	r, err := s.GetRun(id)
	if err != nil || r.State.Ended() {
		return r, nil, err
	}
	var warnings []string
	if claude, err := claudebin.Find(); err != nil {
		warnings = append(warnings, "Could not find claude to stop the session: "+err.Error())
	} else {
		ctx, cancel := context.WithTimeout(ctx, startTimeout)
		defer cancel()
		if out, err := exec.CommandContext(ctx, claude, "stop", sessionRef(r)).CombinedOutput(); err != nil {
			warnings = append(warnings, failureNote("claude stop failed", err, string(out)))
		}
	}
	r, err = s.UpdateRun(id, func(r *store.Run) error {
		r.State, r.Note = store.RunCancelled, "Stopped by you"
		return nil
	})
	return r, warnings, err
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
