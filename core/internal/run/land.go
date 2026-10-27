package run

import (
	"cmp"
	"context"
	"fmt"

	"github.com/GregorMcC/loam/core/internal/linear"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// LandOptions are the choices of a land of a run.
type LandOptions struct {
	// Head is the PR head that you looked at. The merge stops when GitHub
	// has another head (see [worktree.LandOptions]).
	Head string
	// KeepWorktree keeps the worktree after the merge.
	KeepWorktree bool
	// OpenPanes are folders of panes that the caller knows are open.
	OpenPanes []string
	// DryRun changes nothing. The result is the plan.
	DryRun bool
}

// LandResult says what a land of a run did.
type LandResult struct {
	Run      store.Run            `json:"run"`
	Land     *worktree.LandResult `json:"land"`
	Warnings []string             `json:"warnings"`
}

// Land merges the PR of a run that is Ready to land, as loam worktree land
// does, and the run is Landed. Its Linear issue moves to Done. The session
// of the run stops first, because the land removes its worktree. When
// GitHub merges later, with a merge queue, the run stays Ready, and a tick
// lands it when GitHub has merged the PR.
func Land(ctx context.Context, s *store.Store, id string, o LandOptions) (*LandResult, error) {
	r, err := s.GetRun(id)
	if err != nil {
		return nil, err
	}
	if r.State != store.RunReady {
		return nil, fmt.Errorf("only a run that is Ready to land can land, and this run is %s: %w", r.State, store.ErrInvalid)
	}
	if r.PR == nil {
		return nil, fmt.Errorf("the run has no PR, so Loam cannot merge it. Merge its branch yourself: %w", store.ErrInvalid)
	}
	res := &LandResult{Run: r, Warnings: []string{}}
	if !o.DryRun {
		if warning := stopSession(ctx, r); warning != "" {
			res.Warnings = append(res.Warnings, warning)
		}
	}
	land, err := worktree.Land(ctx, s, r.PlotID, r.WorktreeID, worktree.LandOptions{
		Head: o.Head, KeepWorktree: o.KeepWorktree, OpenPanes: o.OpenPanes, DryRun: o.DryRun,
	})
	if err != nil {
		return nil, err
	}
	res.Land = land
	pr := land.PR.Number
	switch {
	case o.DryRun:
		return res, nil
	case land.Merged:
		note := fmt.Sprintf("Merged #%d with %s", pr, land.Method)
		if land.PR.State == "MERGED" {
			note = fmt.Sprintf("#%d was merged on GitHub", pr)
		}
		var warnings []string
		res.Run, _, warnings, err = landRun(ctx, s, r, note)
		res.Warnings = append(res.Warnings, warnings...)
		return res, err
	case land.MergeQueue:
		res.Run, err = noteWhile(s, r, fmt.Sprintf("#%d is in the merge queue of %s", pr, land.PR.Base))
	default:
		res.Run, err = noteWhile(s, r, cmp.Or(land.MergeNote, fmt.Sprintf("GitHub merges #%d when it can", pr)))
	}
	return res, err
}

// landRun marks the run Landed with the note while it is still in the state
// that r has, and records the note as a "land" event. Its Linear issue moves
// to Done. It returns false when the run had moved on.
func landRun(ctx context.Context, s *store.Store, r store.Run, note string) (store.Run, bool, []string, error) {
	from, moved := r.State, false
	r, err := s.UpdateRun(r.ID, func(cur *store.Run) error {
		if cur.State == from {
			cur.State, cur.Note, moved = store.RunLanded, note, true
		}
		return nil
	})
	if err != nil || !moved {
		return r, false, nil, err
	}
	var warnings []string
	if err := s.AddRunEvent(r.ID, "land", note); err != nil {
		warnings = append(warnings, err.Error())
	}
	if warning := moveLinearIssue(ctx, s, r, "Done", "has ended", (*linear.Client).Finish); warning != "" {
		warnings = append(warnings, warning)
	}
	return r, true, warnings, nil
}

// noteWhile sets the note of the run while it is still in the state that r
// has, and records the note as a "land" event.
func noteWhile(s *store.Store, r store.Run, note string) (store.Run, error) {
	from := r.State
	r, err := s.UpdateRun(r.ID, func(cur *store.Run) error {
		if cur.State == from {
			cur.Note = note
		}
		return nil
	})
	if err != nil {
		return r, err
	}
	return r, s.AddRunEvent(r.ID, "land", note)
}
