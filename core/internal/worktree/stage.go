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
	StageBehindBase       Stage = "behind_base"
	StageChecksRunning    Stage = "checks_running"
	StageWaitingForReview Stage = "waiting_for_review"
	StageDraft            Stage = "draft"
	StageReadyToMerge     Stage = "ready_to_merge"
	StagePushedNoPR       Stage = "pushed_no_pr"
	StageNotPushed        Stage = "not_pushed"
	// StageNone means that there is nothing to show.
	StageNone Stage = ""
)

// Stages lists every stage except [StageNone], in the order of the rule.
var Stages = []Stage{
	StageMerged, StageClosed, StageInMergeQueue, StageConflicts, StageChangesRequested,
	StageChecksFailed, StageApprovalNeeded, StageBehindBase, StageChecksRunning,
	StageWaitingForReview, StageDraft, StageReadyToMerge, StagePushedNoPR, StageNotPushed,
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
	// Last is the stage of the last refresh of the same PR.
	Last Stage
}

// StageOf returns the stage of a worktree: the first stage in the order of
// [Stages] that matches. A worktree whose folder is gone shows no stage.
func StageOf(in StageInput) Stage {
	if in.Missing {
		return StageNone
	}
	if in.PR != nil {
		if s := prStage(in.PR, in.Last); s != StageNone {
			return s
		}
	} else if in.Pushed {
		return StagePushedNoPR
	}
	if in.Changed > 0 || in.Unpushed > 0 {
		return StageNotPushed
	}
	return StageNone
}

// prStage returns the stage of a PR, or StageNone when no PR stage matches.
//
// GitHub gives mergeable UNKNOWN while it checks whether a PR can merge, and
// for most merged or closed PRs. The stages from Conflicts on depend on that
// check, so the last stage stays. With no last stage, the stage is Checks
// running. Never show UNKNOWN as a failure.
func prStage(pr *github.PR, last Stage) Stage {
	switch {
	case pr.State == "MERGED":
		return StageMerged
	case pr.State == "CLOSED":
		return StageClosed
	case pr.InMergeQueue:
		return StageInMergeQueue
	case pr.Mergeable == "UNKNOWN":
		if last.isOpenPR() {
			return last
		}
		return StageChecksRunning
	case pr.Mergeable == "CONFLICTING" || pr.MergeState == "DIRTY":
		return StageConflicts
	case pr.ReviewDecision == "CHANGES_REQUESTED":
		return StageChangesRequested
	case requiredCheckFailed(pr):
		return StageChecksFailed
	case pr.Checks.Waiting > 0:
		return StageApprovalNeeded
	case pr.MergeState == "BEHIND":
		return StageBehindBase
	case pr.Checks.State == "PENDING" || pr.Checks.State == "EXPECTED" || pr.Checks.Running > 0:
		return StageChecksRunning
	case pr.ReviewDecision == "REVIEW_REQUIRED":
		return StageWaitingForReview
	case pr.Draft:
		return StageDraft
	case pr.MergeState == "CLEAN" || pr.MergeState == "HAS_HOOKS":
		return StageReadyToMerge
	}
	return StageNone
}

func requiredCheckFailed(pr *github.PR) bool {
	for _, c := range pr.FailedChecks {
		if c.Required {
			return true
		}
	}
	return false
}

// isOpenPR reports whether s is a stage of an open PR: In merge queue to
// Ready to merge.
func (s Stage) isOpenPR() bool {
	switch s {
	case StageInMergeQueue, StageConflicts, StageChangesRequested, StageChecksFailed, StageApprovalNeeded,
		StageBehindBase, StageChecksRunning, StageWaitingForReview, StageDraft, StageReadyToMerge:
		return true
	}
	return false
}
