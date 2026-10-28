package run

import (
	"context"
	"fmt"
	"slices"
	"strings"

	"github.com/GregorMcC/loam/core/internal/intake"
	"github.com/GregorMcC/loam/core/internal/linear"
	"github.com/GregorMcC/loam/core/internal/store"
)

// linearUpdateOff reports whether the update to the Linear issue of the run
// that on picks from the switches is off. Then it records a "linear" event
// that says what Loam did not do. what is that update, such as "move
// ENG-523 to Done". When Loam cannot read the switches, the update is off
// too, and it returns a warning.
func linearUpdateOff(s *store.Store, r store.Run, what string, on func(store.LinearUpdates) bool) (bool, string) {
	u, err := s.GetLinearUpdates()
	if err != nil {
		return true, fmt.Sprintf("Loam did not %s: %v", what, err)
	}
	if on(u) {
		return false, ""
	}
	if err := s.AddRunEvent(r.ID, "linear", fmt.Sprintf("Loam did not %s: that update to Linear is off", what)); err != nil {
		return true, err.Error()
	}
	return true, ""
}

// commentWalkthrough adds the walkthrough of a landed run to its Linear
// issue as a comment, when that update is on and the run has notes and a PR.
// It records what happened as a "linear" event, and returns a warning when
// the comment failed.
func commentWalkthrough(ctx context.Context, s *store.Store, r store.Run) string {
	if r.Source == nil || r.Source.Kind != intake.Linear || r.Notes == nil || r.PR == nil {
		return ""
	}
	u, err := s.GetLinearUpdates()
	if err != nil {
		return err.Error()
	}
	if !u.WalkthroughComment {
		return ""
	}
	key := r.Source.Key
	passed, total := gateChecks(s, r)
	text := fmt.Sprintf("Landed in #%d by a Loam run. %s %d of %d checks passed.",
		r.PR.Number, strings.TrimSpace(r.Notes.Walkthrough), passed, total)
	detail, warning := "Added the walkthrough to "+key+" as a comment", ""
	c, err := linear.FromKeychain()
	if err == nil {
		err = c.Comment(ctx, key, text)
	}
	if err != nil {
		detail = fmt.Sprintf("Could not add the walkthrough to %s: %v", key, err)
		warning = detail
	}
	if err := s.AddRunEvent(r.ID, "linear", detail); err != nil {
		return err.Error()
	}
	return warning
}

// gateChecks counts the checks of the last gate of the run, and the ones that
// passed: the last block of "check" events. A run with no such events counts
// its Done when checks and the committed check, as passed.
func gateChecks(s *store.Store, r store.Run) (passed, total int) {
	events, err := s.RunEvents(r.ID)
	if err == nil {
		for _, e := range slices.Backward(events) {
			if e.Kind != "check" {
				if total > 0 {
					break
				}
				continue
			}
			total++
			if strings.Contains(e.Detail, " passed (") {
				passed++
			}
		}
	}
	if total == 0 {
		total = len(r.DoneWhen) + 1
		passed = total
	}
	return passed, total
}
