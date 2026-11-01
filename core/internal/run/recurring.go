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

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
)

// precheckTimeout is how long the precheck of a recurring run can take.
const precheckTimeout = 2 * time.Minute

// missedAfter is how late a tick can be before the time counts as missed:
// launchd ticks every few minutes, and a Mac that slept ticks later.
const missedAfter = 15 * time.Minute

// precheckOutputMax is how much of the output of a precheck goes to Claude.
const precheckOutputMax = 4000

// RecurringResult is what a tick did with one recurring run: the run that it
// started, or the run that says why it skipped.
type RecurringResult struct {
	Recurring store.Recurring `json:"recurring"`
	// Run is the run that the tick started or skipped, or nil when it made
	// none, such as when the last run has not ended.
	Run  *store.Run `json:"run,omitempty"`
	Note string     `json:"note"`
}

// TickRecurring starts each recurring run that is due at now (ticket 208).
// A time that the Mac slept through counts once. A run whose precheck finds
// no work is Skipped, and starts no session. Two ticks at once never start a
// recurring run twice.
func TickRecurring(ctx context.Context, s *store.Store, now time.Time, loam string) ([]RecurringResult, error) {
	out := []RecurringResult{}
	unlock, ok, err := lockFile(filepath.Join(s.Home(), "recurring-tick.lock"))
	if err != nil || !ok {
		return out, err
	}
	defer unlock()
	all, err := s.ListRecurring("")
	if err != nil {
		return out, err
	}
	for _, r := range all {
		if r.NextAt.After(now) {
			continue
		}
		claimed, err := s.ClaimRecurring(r.ID, r.NextAt, r.NextAfter(now))
		if err != nil {
			return out, err
		}
		if !claimed {
			continue
		}
		asleep := ""
		if now.Sub(r.NextAt) > missedAfter && r.IfAsleep == store.AsleepSkip {
			asleep = fmt.Sprintf("Skipped, because the Mac was asleep at %s", r.NextAt.Format("Mon 15:04"))
		}
		out = append(out, fire(ctx, s, r, now, loam, asleep))
	}
	return out, nil
}

// RunRecurringNow starts a recurring run now, as a tick does when it is due.
// Its next time stays.
func RunRecurringNow(ctx context.Context, s *store.Store, id string, now time.Time, loam string) (RecurringResult, error) {
	r, err := s.GetRecurring(id)
	if err != nil {
		return RecurringResult{}, err
	}
	return fire(ctx, s, r, now, loam, ""), nil
}

// fire starts the recurring run, or skips it with a reason, and records what
// it did. A failure to start is the note, so one bad recurring run never
// stops the tick.
func fire(ctx context.Context, s *store.Store, rec store.Recurring, now time.Time, loam, skip string) RecurringResult {
	res := RecurringResult{Recurring: rec}
	runID := rec.LastRunID
	plot, err := s.GetPlot(rec.PlotID)
	switch {
	case err != nil:
		res.Note = fmt.Sprintf("Loam could not read the plot: %v", err)
	case plot.Archived:
		res.Note = "Not started, because the plot is archived"
	default:
		if open := openRun(s, rec); open != nil {
			// Runs never stack: the next one waits for the last to end.
			res.Note = fmt.Sprintf("Not started, because the last run, %s, is %s", open.ID, open.State)
			break
		}
		repo, err := runRepo(plot, rec.Repo, "")
		if err != nil {
			res.Note = fmt.Sprintf("Not started: %v", err)
			break
		}
		output := ""
		if skip == "" && strings.TrimSpace(rec.Precheck) != "" {
			// A check of an earlier gate can write the commondir file of the git
			// folder, and git in the precheck would follow it outside the sandbox.
			if err := session.CheckGitFolder(repo.Path, repo.Path); err != nil {
				skip = "Skipped, because the precheck did not run: " + err.Error()
			} else {
				output, skip = precheck(ctx, rec.Precheck, repo.Path)
			}
		}
		if skip != "" {
			res.Run, res.Note = skipRun(s, rec, repo.Path, skip)
		} else {
			res.Run, res.Note = startRecurring(ctx, s, rec, output, loam)
		}
		if res.Run != nil {
			runID = res.Run.ID
		}
	}
	if err := s.RecordRecurring(rec.ID, now, res.Note, runID); err == nil {
		if got, err := s.GetRecurring(rec.ID); err == nil {
			res.Recurring = got
		}
	}
	return res
}

// openRun returns a run of the recurring run that has not ended, or nil.
func openRun(s *store.Store, rec store.Recurring) *store.Run {
	runs, err := s.ListRuns(rec.PlotID)
	if err != nil {
		return nil
	}
	for _, r := range runs {
		if r.Source != nil && r.Source.Kind == store.SourceRecurring && r.Source.Key == rec.ID && !r.State.Ended() {
			return &r
		}
	}
	return nil
}

// precheck runs the precheck in the repo. It returns the output of a
// precheck that passed, or the reason to skip.
func precheck(ctx context.Context, command, dir string) (output, skip string) {
	ctx, cancel := context.WithTimeout(ctx, precheckTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/sh", "-c", command)
	cmd.Dir = dir
	cmd.WaitDelay = time.Second // a child that keeps the output open does not hold the tick
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	var exit *exec.ExitError
	switch {
	case ctx.Err() != nil:
		return "", fmt.Sprintf("Skipped, because the precheck took more than %s", precheckTimeout)
	case errors.As(err, &exit) && (exit.ExitCode() == 126 || exit.ExitCode() == 127):
		// The shell could not find or run the command, so the precheck is broken.
		return "", fmt.Sprintf("Skipped, because the precheck could not run its command (exit %d): %s",
			exit.ExitCode(), Tail(strings.TrimSpace(stderr.String()), 3))
	case errors.As(err, &exit):
		return "", fmt.Sprintf("Skipped, because the precheck found no work (exit %d)", exit.ExitCode())
	case err != nil:
		return "", fmt.Sprintf("Skipped, because the precheck did not run: %v", err)
	}
	out := strings.TrimSpace(stdout.String())
	if len(out) > precheckOutputMax {
		out = strings.ToValidUTF8(out[:precheckOutputMax], "") + "\n[Loam cut the rest of the output]"
	}
	return out, ""
}

// skipRun records the skip as a Skipped run that starts no session. A skip
// after a skip changes the last Skipped run, so a quiet week makes one run,
// not seven.
func skipRun(s *store.Store, rec store.Recurring, folder, note string) (*store.Run, string) {
	if rec.LastRunID != "" {
		r, err := s.UpdateRun(rec.LastRunID, func(r *store.Run) error {
			if r.State != store.RunSkipped {
				return store.ErrInvalid
			}
			r.Note = note
			return nil
		})
		if err == nil {
			return &r, note
		}
	}
	r, err := s.AddRun(store.Run{
		PlotID: rec.PlotID, Folder: folder, Title: rec.Title, Goal: rec.Prompt, DoneWhen: rec.DoneWhen,
		State: store.RunSkipped, MaxTries: rec.MaxTries, Note: note, Source: recurringSource(rec),
	})
	if err != nil {
		return nil, fmt.Sprintf("%s. Loam could not record it: %v", note, err)
	}
	return &r, note
}

// startRecurring starts the run: a chore starts its session, and a Shape run
// has Claude draft a run for you to approve. The output of the precheck goes
// to Claude with the prompt.
func startRecurring(ctx context.Context, s *store.Store, rec store.Recurring, output, loam string) (*store.Run, string) {
	brief := rec.Prompt
	if output != "" {
		brief += "\n\nThe precheck printed:\n" + output
	}
	if rec.Kind == store.RecurringShape {
		runs, err := Shape(ctx, s, ShapeOptions{PlotID: rec.PlotID, Title: rec.Title, Repo: rec.Repo, MaxTries: rec.MaxTries,
			Model: rec.Model, Effort: rec.Effort, Brief: brief, Source: recurringSource(rec)})
		if err != nil {
			return nil, fmt.Sprintf("Claude could not shape a run: %v", err)
		}
		r := runs[0]
		if r.Shape == nil || r.Shape.DraftedAt == nil {
			return &r, "Claude could not draft the run. It waits at the desk with the reason"
		}
		return &r, "Claude drafted a run for your approval"
	}
	res, err := Start(ctx, s, StartOptions{PlotID: rec.PlotID, Title: rec.Title, Goal: brief, DoneWhen: rec.DoneWhen,
		Repo: rec.Repo, MaxTries: rec.MaxTries, Model: rec.Model, Effort: rec.Effort, Source: recurringSource(rec), Loam: loam})
	if err != nil {
		return nil, fmt.Sprintf("The run did not start: %v", err)
	}
	switch res.Run.State {
	case store.RunStopped:
		return &res.Run, "The run stopped as it started: " + res.Run.Note
	case store.RunQueued:
		return &res.Run, res.Run.Note
	}
	return &res.Run, "Started a run"
}

func recurringSource(rec store.Recurring) *store.RunSource {
	return &store.RunSource{Kind: store.SourceRecurring, Key: rec.ID, URL: ""}
}

// ApproveRepoSetup approves the setup command of a repo of the plot now, for
// a recurring chore: a tick has no one to ask. hash is the [SetupHash] of the
// command that you read. repoArg is an ID or a path, or empty for the main repo.
func ApproveRepoSetup(s *store.Store, plotID, repoArg, hash string) error {
	plot, err := s.GetPlot(plotID)
	if err != nil {
		return err
	}
	repo, err := runRepo(plot, repoArg, "")
	if err != nil {
		return err
	}
	_, err = approveSetup(s, repo.Path, hash)
	return err
}
