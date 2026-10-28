package run

import (
	"cmp"
	"context"
	"fmt"
	"strings"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/intake"
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
	// NoLinearDone leaves the Linear issue where it is: this land does not
	// move it to Done. It holds only for a land that merges now.
	NoLinearDone bool
}

// LandResult says what a land of a run did.
type LandResult struct {
	Run      store.Run            `json:"run"`
	Land     *worktree.LandResult `json:"land"`
	Warnings []string             `json:"warnings"`
}

// Land merges the PR of a run that is Ready to land, as loam worktree land
// does, and the run is Landed. Its Linear issue moves to Done, unless
// [LandOptions.NoLinearDone] says not to. The session
// of the run stops first, because the land removes its worktree, but only
// when a dry run finds that the land can go on. When
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
	if _, err := s.GetWorktree(r.WorktreeID); err != nil {
		return landGone(ctx, s, r, o, res)
	}
	wo := worktree.LandOptions{Head: o.Head, KeepWorktree: o.KeepWorktree, OpenPanes: o.OpenPanes, DryRun: true}
	plan, err := worktree.Land(ctx, s, r.PlotID, r.WorktreeID, wo)
	if err != nil {
		return nil, err
	}
	if o.DryRun {
		res.Land = plan
		return res, nil
	}
	// A land that refuses, for a check or a new head, keeps the session.
	if plan.Ready && (o.Head == "" || plan.PR.State != "OPEN" || plan.PR.HeadOID == o.Head) {
		if warning := stopSession(ctx, r); warning != "" {
			res.Warnings = append(res.Warnings, warning)
		}
	}
	wo.DryRun = false
	land, err := worktree.Land(ctx, s, r.PlotID, r.WorktreeID, wo)
	if err != nil {
		return nil, err
	}
	res.Land = land
	pr := land.PR.Number
	switch {
	case land.Merged:
		var warnings []string
		res.Run, _, warnings, err = landRun(ctx, s, r, MergedNote(land), !o.NoLinearDone)
		res.Warnings = append(res.Warnings, warnings...)
		return res, err
	case land.MergeQueue:
		res.Run, err = noteWhile(s, r, fmt.Sprintf("#%d is in the merge queue of %s", pr, land.PR.Base))
	default:
		res.Run, err = noteWhile(s, r, cmp.Or(land.MergeNote, fmt.Sprintf("GitHub merges #%d when it can", pr)))
	}
	if o.NoLinearDone && r.Source != nil && r.Source.Kind == intake.Linear {
		res.Warnings = append(res.Warnings, fmt.Sprintf(
			"GitHub merges #%d later. The tick that lands the run then moves its Linear issue to Done when that update to Linear is on", pr))
	}
	return res, err
}

// MergedNote says how a land merged its PR, as the note of a run that it lands.
func MergedNote(land *worktree.LandResult) string {
	if land.PR.State == "MERGED" {
		return fmt.Sprintf("#%d was merged on GitHub", land.PR.Number)
	}
	return fmt.Sprintf("Merged #%d with %s", land.PR.Number, land.Method)
}

// landGone lands a run whose worktree is gone, such as after loam worktree
// land removed it. There is nothing to merge: Loam reads the PR by its number.
// A merged PR lands the run, and a closed PR stops it. An open PR is an
// error, because Loam cannot merge a PR with no worktree.
func landGone(ctx context.Context, s *store.Store, r store.Run, o LandOptions, res *LandResult) (*LandResult, error) {
	repo, ok := github.PRRepo(r.PR.URL)
	if !ok {
		return nil, fmt.Errorf("the worktree of the run is gone, and Loam cannot read the repo of #%d: %w", r.PR.Number, store.ErrInvalid)
	}
	gh, err := github.NewClient()
	if err != nil {
		return nil, err
	}
	st, err := gh.ViewPR(ctx, repo, r.PR.Number)
	if err != nil {
		return nil, err
	}
	if st.State == "OPEN" {
		return nil, fmt.Errorf("the worktree of the run is gone, and #%d is open on GitHub. Merge it on GitHub, or cancel the run: %w", st.Number, store.ErrInvalid)
	}
	if o.DryRun {
		res.Warnings = append(res.Warnings, fmt.Sprintf("The worktree is gone, and #%d is %s on GitHub. A land records that.", st.Number, strings.ToLower(st.State)))
		return res, nil
	}
	sh := shipper{s: s, gh: gh, r: r, noLinearDone: o.NoLinearDone}
	_, _, err = sh.ended(ctx, &github.PR{Number: st.Number, State: st.State})
	res.Run, res.Warnings = sh.r, append(res.Warnings, sh.warnings...)
	return res, err
}

// LandWorktree lands each run of the plot that has not ended and works in the
// worktree, after loam worktree land merged its PR. pr is the merged PR and
// note says how it merged. It returns the runs that it landed, and what went
// wrong on the way.
func LandWorktree(ctx context.Context, s *store.Store, plotID, worktreeID string, pr int, note string) ([]store.Run, []string) {
	runs, err := s.ListRuns(plotID)
	if err != nil {
		return nil, []string{err.Error()}
	}
	var landed []store.Run
	var warnings []string
	for _, r := range runs {
		if r.WorktreeID != worktreeID || (r.State != store.RunShipping && r.State != store.RunReady) {
			continue
		}
		// A run that has its own PR keeps it. Any other PR is the work of the worktree.
		if r.PR != nil && r.PR.Number != pr {
			continue
		}
		r, moved, w, err := landRun(ctx, s, r, note, true)
		warnings = append(warnings, w...)
		if err != nil {
			warnings = append(warnings, err.Error())
		} else if moved {
			landed = append(landed, r)
		}
	}
	return landed, warnings
}

// landRun marks the run Landed with the note while it is still in the state
// that r has, and records the note as a "land" event. With done, its Linear
// issue moves to Done, for a run of a group when no other run of the group is
// left (see [finishLinearIssue]). The issue gets the walkthrough of the run
// as a comment when that update is on (see [commentWalkthrough]). It returns
// false when the run had moved on.
func landRun(ctx context.Context, s *store.Store, r store.Run, note string, done bool) (store.Run, bool, []string, error) {
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
	switch {
	case done:
		if warning := finishLinearIssue(ctx, s, r); warning != "" {
			warnings = append(warnings, warning)
		}
	case r.Source != nil && r.Source.Kind == intake.Linear:
		if err := s.AddRunEvent(r.ID, "linear", "This land leaves "+r.Source.Key+" where it is"); err != nil {
			warnings = append(warnings, err.Error())
		}
	}
	if warning := commentWalkthrough(ctx, s, r); warning != "" {
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
