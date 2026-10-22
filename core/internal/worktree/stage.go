package worktree

import "github.com/GregorMcC/loam/core/internal/github"

// Stage is what a worktree shows about its PR or its branch. [StageOf]
// gives the one stage of a worktree.
type Stage string

// The stages, in the order that [StageOf] checks them.
const (
	StageMerged           Stage = "merged"
	StageClosed           Stage = "closed"
	StageInMergeQueue     Stage = "in_merge_queue"
	StageConflicts        Stage = "conflicts"
	StageChangesRequested Stage = "changes_requested"
	StageChecksFailed     Stage = "checks_failed"
	StageApprovalNeeded   Stage = "approval_needed"
	StageDraft            Stage = "draft"
	StageBehindBase       Stage = "behind_base"
	StageChecksRunning    Stage = "checks_running"
	StageWaitingForReview Stage = "waiting_for_review"
	StageBlocked          Stage = "blocked"
	StageReadyToMerge     Stage = "ready_to_merge"
	StagePushedNoPR       Stage = "pushed_no_pr"
	StageNotPushed        Stage = "not_pushed"
	// StageNone means that there is nothing to show.
	StageNone Stage = ""
)

// Stages lists every stage except [StageNone], in the order of the rule.
var Stages = []Stage{
	StageMerged, StageClosed, StageInMergeQueue, StageConflicts, StageChangesRequested, StageChecksFailed,
	StageApprovalNeeded, StageDraft, StageBehindBase, StageChecksRunning, StageWaitingForReview, StageBlocked,
	StageReadyToMerge, StagePushedNoPR, StageNotPushed,
}

// StageInput is what the stage rule reads: the ship state from GitHub and the
// local checks of the worktree.
type StageInput struct {
	// PR is the pull request of the branch, or nil.
	PR *github.PR
	// Pushed is true when the branch is on GitHub.
	Pushed bool
	// Missing, Changed, and Unpushed are the local checks of [Status].
	Missing  bool
	Changed  int
	Unpushed int
	// HeadInPR is true when the commit that the worktree has checked out is
	// the PR head or an earlier commit of the PR. The rule reads it only for
	// a merged or closed PR.
	HeadInPR bool
	// LocalFailed is true when git could not read the changed files or the
	// unpushed commits. Then the worktree can have work after the PR head.
	LocalFailed bool
	// Last is the stage of the last refresh of the same PR.
	Last Stage
}

// StageOf returns the stage of a worktree: the first stage in the order of
// [Stages] that matches. A worktree whose folder is gone shows no stage. An
// open PR always has a PR stage.
func StageOf(in StageInput) Stage {
	if in.Missing {
		return StageNone
	}
	if in.UsesPR() {
		return prStage(in.PR, in.Last)
	}
	switch {
	case in.Pushed:
		return StagePushedNoPR
	case in.Changed > 0 || in.Unpushed > 0:
		return StageNotPushed
	}
	return StageNone
}

// UsesPR reports whether the stage comes from the PR. It is false with no
// PR, and when the worktree has work after the head of a merged or closed
// PR. Then the stage comes from the local checks, as if there were no PR, so
// Loam never offers to tidy away work that is not in the PR.
//
// The worktree has no work after the PR head when its HEAD is in the PR (see
// [StageInput.HeadInPR]) and git found no changed files. A cache row from before
// Loam stored the PR head has no head to compare, and its PR stage stays.
func (in StageInput) UsesPR() bool {
	pr := in.PR
	if pr == nil {
		return false
	}
	if !isDone(pr) || pr.HeadOID == "" {
		return true
	}
	return in.HeadInPR && in.Changed == 0 && !in.LocalFailed
}

// isDone reports whether a PR is merged or closed.
func isDone(pr *github.PR) bool { return pr.State == "MERGED" || pr.State == "CLOSED" }

// prStage returns the stage of a PR.
//
// GitHub gives mergeable UNKNOWN while it checks whether a PR can merge.
// Conflicts, Behind base, Blocked, and Ready to merge need that check, so
// the rule skips them until GitHub knows. A merge state that Loam does not
// know is handled in the same way. When no other stage matches, the last of
// those four stages stays, else the stage is Checks running. Never show
// UNKNOWN as a failure.
func prStage(pr *github.PR, last Stage) Stage {
	switch pr.State {
	case "MERGED":
		return StageMerged
	case "CLOSED":
		return StageClosed
	}
	checked := mergeChecked(pr)
	switch {
	case pr.InMergeQueue:
		return StageInMergeQueue
	// CONFLICTING is the answer of the merge check, so it needs no merge state.
	case pr.Mergeable == "CONFLICTING" || checked && pr.MergeState == "DIRTY":
		return StageConflicts
	case pr.ReviewDecision == "CHANGES_REQUESTED":
		return StageChangesRequested
	case checksFailed(pr):
		return StageChecksFailed
	case pr.Checks.Waiting > 0:
		return StageApprovalNeeded
	case pr.Draft:
		return StageDraft
	case checked && pr.MergeState == "BEHIND":
		return StageBehindBase
	case pr.Checks.State == "PENDING" || pr.Checks.State == "EXPECTED" || pr.Checks.Running > 0:
		return StageChecksRunning
	case pr.ReviewDecision == "REVIEW_REQUIRED":
		return StageWaitingForReview
	// GitHub gives BLOCKED for each rule that stops the merge. That includes
	// a failed required check that Loam cannot see, because Loam reads only
	// the first 100 checks. So that PR never shows Ready to merge.
	case checked && pr.MergeState == "BLOCKED":
		return StageBlocked
	case checked: // CLEAN, HAS_HOOKS, or UNSTABLE (only optional checks failed)
		return StageReadyToMerge
	case last.needsMergeCheck():
		return last
	}
	return StageChecksRunning
}

// mergeChecked reports whether GitHub has checked whether the PR can merge,
// and gives a merge state that Loam knows.
func mergeChecked(pr *github.PR) bool {
	if pr.Mergeable != "MERGEABLE" && pr.Mergeable != "CONFLICTING" {
		return false
	}
	switch pr.MergeState {
	case "DIRTY", "BEHIND", "BLOCKED", "CLEAN", "HAS_HOOKS", "UNSTABLE":
		return true
	}
	return false
}

// checksFailed reports whether a required check failed. When no check of the
// PR is required, any failed check counts.
func checksFailed(pr *github.PR) bool {
	if pr.Checks.Required == 0 {
		return pr.Checks.Failed > 0
	}
	for _, c := range pr.FailedChecks {
		if c.Required {
			return true
		}
	}
	return false
}

// needsMergeCheck reports whether s is a stage that only GitHub's merge check
// can give: Conflicts, Behind base, Blocked, or Ready to merge.
func (s Stage) needsMergeCheck() bool {
	switch s {
	case StageConflicts, StageBehindBase, StageBlocked, StageReadyToMerge:
		return true
	}
	return false
}
