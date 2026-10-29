package run

import (
	"context"
	"fmt"
	"slices"

	"github.com/GregorMcC/loam/core/internal/sandbox"
	"github.com/GregorMcC/loam/core/internal/store"
)

// noChange is a run update that changes nothing, for [store.Store.TakeSlot]
// on a run that already holds a slot.
func noChange(*store.Run) error { return nil }

// startQueued starts the Queued runs, oldest first, while a slot is free and
// the week's usage is under the hold. When a slot is free and the hold needs
// the usage, and Loam read it more than [UsageMaxAge] ago, it probes the
// usage first. A run that still waits gets a new note only when the reason
// changed, so a tick that starts nothing writes nothing. It returns the runs
// that it moved, and the warnings.
func startQueued(ctx context.Context, s *store.Store, loam string) ([]store.Run, []string) {
	runs, err := s.ListRuns("")
	if err != nil {
		return nil, []string{err.Error()}
	}
	var queued []store.Run
	holding := 0
	for _, r := range runs {
		switch {
		case r.State == store.RunQueued:
			queued = append(queued, r)
		case r.State.HoldsSlot():
			holding++
		}
	}
	if len(queued) == 0 {
		return nil, nil
	}
	slices.Reverse(queued) // the list is newest first
	var moved []store.Run
	var warnings []string
	if err := sandbox.Available(); err != nil {
		// No run starts. Each one waits, with the reason as its note.
		for _, r := range queued {
			if note := sandboxNote(err); r.Note != note {
				if err := renote(s, r.ID, note); err != nil {
					warnings = append(warnings, fmt.Sprintf("%s: %v", r.Title, err))
				}
			}
		}
		return nil, warnings
	}
	if warning := freshUsage(ctx, s, holding); warning != "" {
		warnings = append(warnings, warning)
	}
	for _, r := range queued {
		hold, err := s.SlotHold(r.ID)
		if err != nil {
			warnings = append(warnings, fmt.Sprintf("%s: %v", r.Title, err))
			continue
		}
		if hold != "" {
			if hold != r.Note {
				if err := renote(s, r.ID, hold); err != nil {
					warnings = append(warnings, fmt.Sprintf("%s: %v", r.Title, err))
				}
			}
			continue
		}
		r, ws := startOne(ctx, s, r.ID, loam)
		warnings = append(warnings, ws...)
		if r != nil {
			moved = append(moved, *r)
		}
	}
	return moved, warnings
}

// freshUsage probes the usage when the hold needs it: the hold is on, a slot
// is free, and Loam read the usage more than [UsageMaxAge] ago. Loam tries
// at most one probe in that time, so a probe that fails does not run again
// on each tick (see [probeStale]). holding is how many runs hold a slot. It
// returns a warning when the probe fails.
func freshUsage(ctx context.Context, s *store.Store, holding int) string {
	l, err := s.GetRunLimits()
	if err != nil {
		return err.Error()
	}
	if l.HoldAt == 0 || holding >= l.AtATime {
		return ""
	}
	return probeStale(ctx, s)
}

// sandboxNote is the note of a run that waits for the sandbox.
func sandboxNote(err error) string { return "Waits for the sandbox: " + err.Error() }

// renote gives a Queued run the note that says why it waits now. A run that
// left Queued meanwhile stays as it is.
func renote(s *store.Store, id, note string) error {
	_, err := s.UpdateRun(id, func(r *store.Run) error {
		if r.State == store.RunQueued {
			r.Note = note
		}
		return nil
	})
	return err
}

// startOne takes a slot for the Queued run id and starts its session: a new
// session, or a resume of its own session with the prompt of its queue. It
// returns the run when it moved, and warnings for a person to read.
func startOne(ctx context.Context, s *store.Store, id, loam string) (*store.Run, []string) {
	var q *store.RunQueue
	took := false
	r, err := s.TakeSlot(id, nil, func(r *store.Run) error {
		if r.State != store.RunQueued {
			return nil // you cancelled it meanwhile
		}
		q, took = r.Queue, true
		if q == nil {
			q = &store.RunQueue{}
		}
		r.State, r.Note = store.RunStarting, ""
		if q.Resume != "" {
			r.State, r.TurnBase = store.RunRunning, r.Turns // the turn limit counts from the resume
		}
		return nil
	})
	switch {
	case err != nil:
		return nil, []string{fmt.Sprintf("%s: %v", id, err)}
	case !took:
		return nil, nil
	case r.State == store.RunQueued:
		return nil, nil // another start took the slot first
	case q.Resume != "":
		if err := send(ctx, r, q.Resume); err != nil {
			_ = stopAfter(s, r.ID, fmt.Errorf("could not resume the session: %w", err))
			if got, err := s.GetRun(r.ID); err == nil {
				r = got
			}
		}
		return &r, nil
	}
	res, err := launch(ctx, s, r, StartOptions{Model: q.Model, Effort: q.Effort, Loam: loam}, &StartResult{})
	if err != nil {
		if got, gerr := s.GetRun(r.ID); gerr == nil {
			r = got
		}
		return &r, []string{fmt.Sprintf("%s: %v", r.Title, err)}
	}
	var warnings []string
	for _, w := range res.Warnings {
		warnings = append(warnings, fmt.Sprintf("%s: %s", r.Title, w))
	}
	return &res.Run, warnings
}
