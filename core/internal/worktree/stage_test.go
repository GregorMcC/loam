package worktree_test

import (
	"slices"
	"testing"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// head is a made-up commit at the head of a PR.
const head = "1111111111111111111111111111111111111111"

// open returns an open PR that GitHub can merge, with passed checks: it is
// ready to merge until a test changes it.
func open(change func(*github.PR)) *github.PR {
	pr := &github.PR{Number: 12, State: "OPEN", HeadOID: head, Mergeable: "MERGEABLE", MergeState: "CLEAN",
		Checks: github.Checks{State: "SUCCESS", Total: 2, Passed: 2, Required: 1, RequiredPassed: 1}, FailedChecks: []github.Check{}}
	change(pr)
	return pr
}

// done returns a merged or closed PR whose head is the made-up commit.
func done(state string) *github.PR {
	return &github.PR{Number: 12, State: state, HeadOID: head, Mergeable: "UNKNOWN", MergeState: "UNKNOWN", FailedChecks: []github.Check{}}
}

func TestStagesAreInTheOrderOfTheRule(t *testing.T) {
	want := []worktree.Stage{"merged", "closed", "in_merge_queue", "conflicts", "changes_requested", "checks_failed",
		"approval_needed", "draft", "behind_base", "checks_running", "waiting_for_review", "blocked", "ready_to_merge",
		"pushed_no_pr", "not_pushed"}
	if !slices.Equal(worktree.Stages, want) {
		t.Fatalf("got %q", worktree.Stages)
	}
}

func TestStageRule(t *testing.T) {
	required := []github.Check{{Name: "test", Required: true}}
	optional := []github.Check{{Name: "lint"}}
	failRequired := func(p *github.PR) { p.FailedChecks, p.Checks.Failed, p.Checks.RequiredPassed = required, 1, 0 }
	unknown := func(p *github.PR) { p.Mergeable, p.MergeState = "UNKNOWN", "UNKNOWN" }
	for _, c := range []struct {
		name string
		in   worktree.StageInput
		want worktree.Stage
	}{
		// One row for each stage, in the order of the rule. Each row also
		// matches a later stage, so the order shows.
		{"merged", worktree.StageInput{PR: done("MERGED"), HeadInPR: true, Pushed: true, Unpushed: 3}, worktree.StageMerged},
		{"closed", worktree.StageInput{PR: done("CLOSED"), HeadInPR: true, Pushed: true}, worktree.StageClosed},
		{"in merge queue", worktree.StageInput{PR: open(func(p *github.PR) { p.InMergeQueue, p.Mergeable = true, "CONFLICTING" })}, worktree.StageInMergeQueue},
		{"conflicts", worktree.StageInput{PR: open(func(p *github.PR) { p.Mergeable, p.ReviewDecision = "CONFLICTING", "CHANGES_REQUESTED" })}, worktree.StageConflicts},
		{"conflicts by merge state", worktree.StageInput{PR: open(func(p *github.PR) { p.MergeState, p.ReviewDecision = "DIRTY", "CHANGES_REQUESTED" })}, worktree.StageConflicts},
		{"changes requested", worktree.StageInput{PR: open(func(p *github.PR) { p.ReviewDecision = "CHANGES_REQUESTED"; failRequired(p) })}, worktree.StageChangesRequested},
		{"checks failed", worktree.StageInput{PR: open(func(p *github.PR) { failRequired(p); p.Checks.Waiting = 1 })}, worktree.StageChecksFailed},
		{"approval needed", worktree.StageInput{PR: open(func(p *github.PR) { p.Checks.Waiting, p.Draft = 1, true })}, worktree.StageApprovalNeeded},
		{"draft", worktree.StageInput{PR: open(func(p *github.PR) { p.Draft, p.MergeState = true, "BEHIND" })}, worktree.StageDraft},
		{"behind base", worktree.StageInput{PR: open(func(p *github.PR) { p.MergeState, p.Checks.State = "BEHIND", "PENDING" })}, worktree.StageBehindBase},
		{"checks running", worktree.StageInput{PR: open(func(p *github.PR) { p.Checks.State, p.ReviewDecision = "PENDING", "REVIEW_REQUIRED" })}, worktree.StageChecksRunning},
		{"checks expected", worktree.StageInput{PR: open(func(p *github.PR) { p.Checks.State = "EXPECTED" })}, worktree.StageChecksRunning},
		{"a check still runs", worktree.StageInput{PR: open(func(p *github.PR) { p.Checks.Running = 1 })}, worktree.StageChecksRunning},
		{"waiting for review", worktree.StageInput{PR: open(func(p *github.PR) { p.ReviewDecision, p.MergeState = "REVIEW_REQUIRED", "BLOCKED" })}, worktree.StageWaitingForReview},
		{"blocked", worktree.StageInput{PR: open(func(p *github.PR) { p.MergeState = "BLOCKED" })}, worktree.StageBlocked},
		{"ready to merge", worktree.StageInput{PR: open(func(*github.PR) {}), Changed: 1}, worktree.StageReadyToMerge},
		{"ready to merge with hooks", worktree.StageInput{PR: open(func(p *github.PR) { p.MergeState = "HAS_HOOKS" })}, worktree.StageReadyToMerge},
		{"pushed, no PR", worktree.StageInput{Pushed: true, Unpushed: 4}, worktree.StagePushedNoPR},
		{"not pushed: commits", worktree.StageInput{Unpushed: 4}, worktree.StageNotPushed},
		{"not pushed: changed files", worktree.StageInput{Changed: 2}, worktree.StageNotPushed},
		{"nothing to show", worktree.StageInput{}, worktree.StageNone},

		// Checks failed: a required check failed. When no check is required,
		// any failed check counts.
		{"unstable: an optional check failed and the required checks passed", worktree.StageInput{PR: open(func(p *github.PR) {
			p.MergeState, p.FailedChecks, p.Checks.Failed = "UNSTABLE", optional, 1
		})}, worktree.StageReadyToMerge},
		{"a failed check with no required check", worktree.StageInput{PR: open(func(p *github.PR) {
			p.FailedChecks, p.Checks.Failed, p.Checks.Required, p.Checks.RequiredPassed = optional, 1, 0, 0
		})}, worktree.StageChecksFailed},

		// GitHub still checks whether the PR can merge. Only Conflicts, Behind
		// base, Blocked, and Ready to merge need that check.
		{"unknown keeps ready to merge", worktree.StageInput{PR: open(unknown), Last: worktree.StageReadyToMerge}, worktree.StageReadyToMerge},
		{"conflicting with an unknown merge state", worktree.StageInput{PR: open(func(p *github.PR) { p.Mergeable, p.MergeState = "CONFLICTING", "UNKNOWN" })}, worktree.StageConflicts},
		{"unknown keeps conflicts", worktree.StageInput{PR: open(unknown), Last: worktree.StageConflicts}, worktree.StageConflicts},
		{"unknown keeps behind base", worktree.StageInput{PR: open(unknown), Last: worktree.StageBehindBase}, worktree.StageBehindBase},
		{"unknown keeps blocked", worktree.StageInput{PR: open(unknown), Last: worktree.StageBlocked}, worktree.StageBlocked},
		{"unknown with no last stage", worktree.StageInput{PR: open(unknown)}, worktree.StageChecksRunning},
		{"unknown after a stage that needs no merge check", worktree.StageInput{PR: open(unknown), Last: worktree.StageChecksFailed}, worktree.StageChecksRunning},
		{"unknown after a stage with no open PR", worktree.StageInput{PR: open(unknown), Last: worktree.StagePushedNoPR}, worktree.StageChecksRunning},
		{"unknown skips the rows that need the merge check", worktree.StageInput{PR: open(func(p *github.PR) { p.Mergeable, p.MergeState = "UNKNOWN", "DIRTY" })}, worktree.StageChecksRunning},
		{"unknown still shows changes requested", worktree.StageInput{PR: open(func(p *github.PR) { unknown(p); p.ReviewDecision = "CHANGES_REQUESTED" }), Last: worktree.StageReadyToMerge}, worktree.StageChangesRequested},
		{"unknown still shows checks failed", worktree.StageInput{PR: open(func(p *github.PR) { unknown(p); failRequired(p) }), Last: worktree.StageReadyToMerge}, worktree.StageChecksFailed},
		{"unknown still shows approval needed", worktree.StageInput{PR: open(func(p *github.PR) { unknown(p); p.Checks.Waiting = 1 }), Last: worktree.StageReadyToMerge}, worktree.StageApprovalNeeded},
		{"unknown still shows a draft", worktree.StageInput{PR: open(func(p *github.PR) { unknown(p); p.Draft = true }), Last: worktree.StageReadyToMerge}, worktree.StageDraft},
		{"unknown still shows checks running", worktree.StageInput{PR: open(func(p *github.PR) { unknown(p); p.Checks.Running = 1 }), Last: worktree.StageReadyToMerge}, worktree.StageChecksRunning},
		{"unknown still shows waiting for review", worktree.StageInput{PR: open(func(p *github.PR) { unknown(p); p.ReviewDecision = "REVIEW_REQUIRED" }), Last: worktree.StageBlocked}, worktree.StageWaitingForReview},
		{"unknown does not hide a merge", worktree.StageInput{PR: done("MERGED"), HeadInPR: true, Last: worktree.StageReadyToMerge}, worktree.StageMerged},

		// A merge state that Loam does not know is handled as UNKNOWN. An open
		// PR never falls through to the local rows.
		{"a new merge state keeps the last stage", worktree.StageInput{PR: open(func(p *github.PR) { p.MergeState = "SOME_NEW_STATE" }), Last: worktree.StageBlocked}, worktree.StageBlocked},
		{"a new merge state with no last stage", worktree.StageInput{PR: open(func(p *github.PR) { p.MergeState = "SOME_NEW_STATE" }), Pushed: true, Changed: 1}, worktree.StageChecksRunning},
		{"an unknown merge state with a known mergeable", worktree.StageInput{PR: open(func(p *github.PR) { p.MergeState = "UNKNOWN" }), Unpushed: 1}, worktree.StageChecksRunning},

		// Merged and Closed win only when the worktree has no work after the PR head.
		{"squash merged, and GitHub deleted the branch", worktree.StageInput{PR: done("MERGED"), HeadInPR: true, Pushed: false, Unpushed: 2}, worktree.StageMerged},
		{"merged, then new commits that are on GitHub", worktree.StageInput{PR: done("MERGED"), Pushed: true, Unpushed: 1}, worktree.StagePushedNoPR},
		{"merged, then new commits", worktree.StageInput{PR: done("MERGED"), Unpushed: 1}, worktree.StageNotPushed},
		{"merged, then changed files", worktree.StageInput{PR: done("MERGED"), HeadInPR: true, Changed: 1}, worktree.StageNotPushed},
		{"closed, then new commits", worktree.StageInput{PR: done("CLOSED"), Unpushed: 1}, worktree.StageNotPushed},
		{"merged, and the local head is not known", worktree.StageInput{PR: done("MERGED"), Unpushed: 1}, worktree.StageNotPushed},
		{"an old cache row with no PR head stays merged", worktree.StageInput{PR: &github.PR{State: "MERGED", Mergeable: "UNKNOWN"}, Changed: 1}, worktree.StageMerged},

		{"a missing folder shows no stage", worktree.StageInput{PR: open(func(*github.PR) {}), Missing: true, Unpushed: 1}, worktree.StageNone},
	} {
		if got := worktree.StageOf(c.in); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

// UsesPR reports whether the stage comes from the PR, so the list shows the
// PR. New work after a merged or closed PR shows as if there were no PR.
func TestStageInputUsesThePR(t *testing.T) {
	for _, c := range []struct {
		name string
		in   worktree.StageInput
		want bool
	}{
		{"an open PR", worktree.StageInput{PR: open(func(*github.PR) {})}, true},
		{"merged with no work after it", worktree.StageInput{PR: done("MERGED"), HeadInPR: true}, true},
		{"merged, then new commits", worktree.StageInput{PR: done("MERGED"), Unpushed: 1}, false},
		{"no PR", worktree.StageInput{Pushed: true}, false},
	} {
		if got := c.in.UsesPR(); got != c.want {
			t.Errorf("%s: got %v", c.name, got)
		}
	}
}
