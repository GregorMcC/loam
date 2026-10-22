package worktree_test

import (
	"testing"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// open returns an open PR that GitHub can merge, with no stage of its own
// until a test changes it.
func open(change func(*github.PR)) *github.PR {
	pr := &github.PR{Number: 12, State: "OPEN", Mergeable: "MERGEABLE", MergeState: "BLOCKED", Checks: github.Checks{State: "SUCCESS"}}
	change(pr)
	return pr
}

func TestStageRule(t *testing.T) {
	required := []github.Check{{Name: "test", Required: true}}
	for _, c := range []struct {
		name string
		in   worktree.StageInput
		want worktree.Stage
	}{
		// One row for each stage, in the order of the rule.
		{"merged", worktree.StageInput{PR: &github.PR{State: "MERGED", Mergeable: "UNKNOWN"}, Pushed: true}, worktree.StageMerged},
		{"closed", worktree.StageInput{PR: &github.PR{State: "CLOSED", Mergeable: "UNKNOWN"}}, worktree.StageClosed},
		{"in merge queue", worktree.StageInput{PR: open(func(p *github.PR) { p.InMergeQueue, p.Mergeable = true, "CONFLICTING" })}, worktree.StageInMergeQueue},
		{"conflicts", worktree.StageInput{PR: open(func(p *github.PR) { p.Mergeable, p.ReviewDecision = "CONFLICTING", "CHANGES_REQUESTED" })}, worktree.StageConflicts},
		{"conflicts by merge state", worktree.StageInput{PR: open(func(p *github.PR) { p.MergeState = "DIRTY" })}, worktree.StageConflicts},
		{"changes requested", worktree.StageInput{PR: open(func(p *github.PR) { p.ReviewDecision, p.FailedChecks = "CHANGES_REQUESTED", required })}, worktree.StageChangesRequested},
		{"checks failed", worktree.StageInput{PR: open(func(p *github.PR) { p.FailedChecks, p.Checks.Waiting = required, 1 })}, worktree.StageChecksFailed},
		{"approval needed", worktree.StageInput{PR: open(func(p *github.PR) { p.Checks.Waiting, p.MergeState = 1, "BEHIND" })}, worktree.StageApprovalNeeded},
		{"behind base", worktree.StageInput{PR: open(func(p *github.PR) { p.MergeState, p.Checks.State = "BEHIND", "PENDING" })}, worktree.StageBehindBase},
		{"checks running", worktree.StageInput{PR: open(func(p *github.PR) { p.Checks.State, p.ReviewDecision = "PENDING", "REVIEW_REQUIRED" })}, worktree.StageChecksRunning},
		{"checks expected", worktree.StageInput{PR: open(func(p *github.PR) { p.Checks.State = "EXPECTED" })}, worktree.StageChecksRunning},
		{"waiting for review", worktree.StageInput{PR: open(func(p *github.PR) { p.ReviewDecision, p.Draft = "REVIEW_REQUIRED", true })}, worktree.StageWaitingForReview},
		{"draft", worktree.StageInput{PR: open(func(p *github.PR) { p.Draft, p.MergeState = true, "CLEAN" })}, worktree.StageDraft},
		{"ready to merge", worktree.StageInput{PR: open(func(p *github.PR) { p.MergeState = "CLEAN" })}, worktree.StageReadyToMerge},
		{"ready to merge with hooks", worktree.StageInput{PR: open(func(p *github.PR) { p.MergeState = "HAS_HOOKS" })}, worktree.StageReadyToMerge},
		{"pushed, no PR", worktree.StageInput{Pushed: true, Unpushed: 4}, worktree.StagePushedNoPR},
		{"not pushed: commits", worktree.StageInput{Unpushed: 4}, worktree.StageNotPushed},
		{"not pushed: changed files", worktree.StageInput{Changed: 2}, worktree.StageNotPushed},
		{"nothing to show", worktree.StageInput{}, worktree.StageNone},

		// GitHub still checks whether the PR can merge: the last stage stays.
		{"unknown keeps the last stage", worktree.StageInput{PR: open(func(p *github.PR) { p.Mergeable, p.MergeState = "UNKNOWN", "UNKNOWN" }), Last: worktree.StageReadyToMerge}, worktree.StageReadyToMerge},
		{"unknown with no last stage", worktree.StageInput{PR: open(func(p *github.PR) { p.Mergeable, p.MergeState = "UNKNOWN", "UNKNOWN" })}, worktree.StageChecksRunning},
		{"unknown after a stage with no open PR", worktree.StageInput{PR: open(func(p *github.PR) { p.Mergeable = "UNKNOWN" }), Last: worktree.StagePushedNoPR}, worktree.StageChecksRunning},
		{"unknown does not hide a merge", worktree.StageInput{PR: &github.PR{State: "MERGED", Mergeable: "UNKNOWN"}, Last: worktree.StageReadyToMerge}, worktree.StageMerged},

		// GitHub deleted the head branch after the merge. The PR still shows.
		{"deleted head branch", worktree.StageInput{PR: &github.PR{State: "MERGED", Mergeable: "UNKNOWN"}, Pushed: false}, worktree.StageMerged},

		// Other cases.
		{"a failed check that is not required", worktree.StageInput{PR: open(func(p *github.PR) {
			p.FailedChecks, p.Checks.State, p.Checks.Running = []github.Check{{Name: "lint"}}, "FAILURE", 2
		})}, worktree.StageChecksRunning},
		{"an open PR that matches no stage falls to the local checks", worktree.StageInput{PR: open(func(p *github.PR) { p.MergeState = "UNSTABLE" }), Changed: 1}, worktree.StageNotPushed},
		{"an open PR that matches no stage", worktree.StageInput{PR: open(func(p *github.PR) { p.MergeState = "UNSTABLE" }), Pushed: true}, worktree.StageNone},
		{"a missing folder shows no stage", worktree.StageInput{PR: open(func(p *github.PR) { p.MergeState = "CLEAN" }), Missing: true, Unpushed: 1}, worktree.StageNone},
	} {
		if got := worktree.StageOf(c.in); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}
