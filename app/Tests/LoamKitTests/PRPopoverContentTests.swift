import Foundation
import Testing

@testable import LoamKit

/// Ticket 109: what the PR popover says. The worktrees come from the `worktree_list_stages` fixture
/// (made-up example/widgets data, PRs 11 to 24): one worktree for each stage, then a second Ready to
/// merge whose optional checks failed. The fixture times are 2026-01-01T00:00:00Z.
private func stageRows() throws -> [WorktreeStatus] {
    try JSONDecoder().decode([WorktreeStatus].self, from: Fixtures.data("worktree_list_stages"))
}

private func row(_ stage: WorktreeStage, in rows: [WorktreeStatus]) throws -> WorktreeStatus {
    try #require(rows.first { $0.stage == stage })
}

private let utc = TimeZone(identifier: "UTC")!
private let sameDay = ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z")!
private let later = ISO8601DateFormatter().date(from: "2026-01-01T12:14:00Z")!

private func content(_ status: WorktreeStatus, attemptedAt: Date? = nil,
                     built: Set<PRPrimaryAction> = []) -> PRPopoverContent {
    PRPopoverContent(status, attemptedAt: attemptedAt, now: sameDay, timeZone: utc, built: built)
}

private func text(_ parts: [StatusLine.Part]) -> String { parts.map(\.text).joined(separator: StatusLine.separator) }

// MARK: The phrases of the rows

/// A new phrase goes in `StatusLine` (ticket 108), so one type writes all the status words.
@Suite struct PRRowPhraseTests {
    @Test func checksSayHowManyFailedAndPassed() throws {
        let failed = try #require(try row(.checksFailed, in: stageRows()).pr)
        // The board reads "2 failed · 12 passed". The fixture has 3 checks.
        #expect(StatusLine.checks(of: failed) == [StatusLine.Part(text: "2 failed", failing: true), StatusLine.Part(text: "1 passed")])
    }

    @Test func checksThatAllPassedSayAllOfThem() throws {
        let ready = try #require(try row(.readyToMerge, in: stageRows()).pr)
        #expect(StatusLine.checks(of: ready) == [StatusLine.Part(text: "1 of 1 passed")])
    }

    @Test func checksThatRunSayHowManyAreDone() throws {
        let running = try #require(try row(.checksRunning, in: stageRows()).pr)
        #expect(text(StatusLine.checks(of: running)) == "1 of 2 done")
    }

    @Test func checksThatWaitForApprovalSaySo() throws {
        let waiting = try #require(try row(.approvalNeeded, in: stageRows()).pr)
        #expect(text(StatusLine.checks(of: waiting)) == "1 of 2 done \u{00B7} 1 workflow waits for approval")
    }

    @Test func aFailedCheckThatTheMergeDoesNotNeedIsNotFailing() throws {
        let unstable = try #require(try stageRows().last?.pr)
        let parts = StatusLine.checks(of: unstable)
        #expect(text(parts) == "2 optional failed \u{00B7} 2 passed")
        #expect(parts.allSatisfy { !$0.failing })
    }

    @Test func whenNoCheckIsRequiredAnyFailedCheckFails() throws {
        var failed = try #require(try row(.checksFailed, in: stageRows()).pr)
        failed.checks.required = 0
        failed.failedChecks = failed.failedChecks.map { var check = $0; check.required = false; return check }
        #expect(StatusLine.checks(of: failed).first == StatusLine.Part(text: "2 failed", failing: true))
    }

    @Test func aHeadWithNoChecksSaysSo() throws {
        var pr = try #require(try row(.readyToMerge, in: stageRows()).pr)
        pr.checks = PRCheckCounts(state: "", total: 0, passed: 0, failed: 0, running: 0, waiting: 0, required: 0, requiredPassed: 0)
        #expect(text(StatusLine.checks(of: pr)) == "No checks")
    }

    @Test func theReviewNamesTheDecisionAndWhatBacksIt() throws {
        let rows = try stageRows()
        #expect(text(StatusLine.review(of: try #require(try row(.readyToMerge, in: rows).pr))) == "Approved \u{00B7} 1 approval")
        #expect(text(StatusLine.review(of: try #require(try row(.changesRequested, in: rows).pr))) == "Changes requested \u{00B7} 3 comments")
        #expect(text(StatusLine.review(of: try #require(try row(.waitingForReview, in: rows).pr))) == "Review required")
        // GitHub gives no count of the approvals that a merge needs, so the phrase counts the approvals made.
        var some = try #require(try row(.waitingForReview, in: rows).pr)
        some.approvals = 2
        #expect(text(StatusLine.review(of: some)) == "Review required \u{00B7} 2 approvals")
        #expect(text(StatusLine.review(of: try #require(try row(.draft, in: rows).pr))) == "No review required")
    }

    @Test func approvalsCountEvenWhenTheBaseBranchNeedsNoReview() throws {
        var pr = try #require(try row(.draft, in: stageRows()).pr)
        pr.reviewDecision = ""
        pr.approvals = 2
        #expect(text(StatusLine.review(of: pr)) == "Approved \u{00B7} 2 approvals")
    }

    @Test func checksThatFailedAndAlsoRunSayBoth() throws {
        var pr = try #require(try row(.checksFailed, in: stageRows()).pr)
        pr.checks.total = 6
        pr.checks.running = 3
        pr.checks.waiting = 2
        #expect(text(StatusLine.checks(of: pr)) == "2 failed \u{00B7} 1 passed \u{00B7} 3 running \u{00B7} 2 workflows wait for approval")
    }

    @Test func checksThatAreCancelledCountOnlyInTheTotal() throws {
        var pr = try #require(try row(.readyToMerge, in: stageRows()).pr)
        pr.checks.total = 3
        pr.checks.passed = 2
        #expect(text(StatusLine.checks(of: pr)) == "2 of 3 passed")
    }

    @Test func checksThatGitHubExpectsButHasNotStartedSayTheyWait() throws {
        var pr = try #require(try row(.readyToMerge, in: stageRows()).pr)
        pr.checks = PRCheckCounts(state: "EXPECTED", total: 0, passed: 0, failed: 0, running: 0, waiting: 0)
        #expect(text(StatusLine.checks(of: pr)) == "Waiting for checks")
    }

    @Test func theBaseSaysHowFarBehind() throws {
        let rows = try stageRows()
        #expect(text(StatusLine.base(of: try #require(try row(.behindBase, in: rows).pr))) == "3 commits behind main")
        #expect(text(StatusLine.base(of: try #require(try row(.readyToMerge, in: rows).pr))) == "Up to date with main")
        var one = try #require(try row(.behindBase, in: rows).pr)
        one.behindBase = 1
        #expect(text(StatusLine.base(of: one)) == "1 commit behind main")
    }

    @Test func conflictsAreFailingAndGitHubStillCheckingIsNot() throws {
        let rows = try stageRows()
        #expect(StatusLine.conflicts(of: try #require(try row(.conflicts, in: rows).pr))
                == [StatusLine.Part(text: "Conflicts with main", failing: true)])
        #expect(text(StatusLine.conflicts(of: try #require(try row(.readyToMerge, in: rows).pr))) == "None")
        var checking = try #require(try row(.readyToMerge, in: rows).pr)
        checking.mergeable = "UNKNOWN"
        checking.mergeState = "UNKNOWN"
        let parts = StatusLine.conflicts(of: checking)
        #expect(text(parts) == "Checking\u{2026}" && !parts[0].failing)
        // A PR that GitHub marks conflicting shows it also while the merge state is unknown (the stage rule).
        checking.mergeable = "CONFLICTING"
        #expect(StatusLine.conflicts(of: checking).first?.failing == true)
    }

    @Test func onlyConflictsAndFailedChecksTakeRust() throws {
        let rows = try stageRows()
        var failing: [WorktreeStage] = []
        for status in rows {
            guard let pr = status.pr, pr.state == "OPEN" else { continue }
            let parts = StatusLine.checks(of: pr) + StatusLine.review(of: pr) + StatusLine.base(of: pr) + StatusLine.conflicts(of: pr)
            if parts.contains(where: \.failing), let stage = status.stage { failing.append(stage) }
        }
        #expect(failing == [.conflicts, .checksFailed])
    }
}

// MARK: The content

@Suite struct PRPopoverContentTests {
    // MARK: Every stage

    /// The rows and the buttons of each stage that comes from a PR. With no button built, the primary is nil.
    @Test func eachOpenStageHasTheFourRowsAndItsButtons() throws {
        let rows = try stageRows()
        // stage, secondary buttons
        let expected: [(WorktreeStage, [PRSecondaryAction])] = [
            (.inMergeQueue, [.openOnGitHub]),
            (.conflicts, [.openOnGitHub]),
            (.changesRequested, [.openOnGitHub]),
            (.checksFailed, [.rerunFailed, .openOnGitHub]),
            (.approvalNeeded, [.openOnGitHub]),
            (.draft, [.openOnGitHub]),
            (.behindBase, [.updateBranch, .openOnGitHub]),
            (.checksRunning, [.openOnGitHub]),
            (.waitingForReview, [.openOnGitHub]),
            (.blocked, [.openOnGitHub]),
            (.readyToMerge, [.openOnGitHub]),
        ]
        for (stage, buttons) in expected {
            let popover = content(try row(stage, in: rows))
            #expect(popover.rows.map(\.label) == ["Checks", "Review", "Base", "Conflicts"], "\(stage)")
            #expect(popover.stage == stage, "\(stage)")
            #expect(popover.secondary == buttons, "\(stage)")
            #expect(popover.primary == nil, "\(stage)")
            #expect(popover.hasPullRequest, "\(stage)")
        }
    }

    @Test func aMergedOrClosedPRHasOneRowAndOpensOnGitHub() throws {
        let rows = try stageRows()
        let merged = content(try row(.merged, in: rows))
        #expect(merged.rows.map(\.label) == ["State"] && text(merged.rows[0].parts) == "Merged 00:00")
        #expect(merged.secondary == [.openOnGitHub] && merged.failedChecks.isEmpty)
        let closed = content(try row(.closed, in: rows))
        #expect(closed.rows.map(\.label) == ["State"] && text(closed.rows[0].parts) == "Closed without a merge")
        #expect(closed.secondary == [.openOnGitHub])
    }

    /// The board: "Ready to merge", "#142 Link labels from plot brief", "link-labels → main · 9 commits",
    /// then Checks, Review, Base and Conflicts.
    @Test func theReadyPopoverReadsLikeTheBoard() throws {
        let ready = content(try row(.readyToMerge, in: stageRows()))
        #expect(ready.stage == .readyToMerge)
        #expect(ready.title == "#22 Link labels")
        #expect(ready.subtitle == "link-labels \u{2192} main \u{00B7} 9 commits")
        #expect(ready.updated == "Updated 00:00")
        #expect(ready.rows.map { text($0.parts) } == ["1 of 1 passed", "Approved \u{00B7} 1 approval", "Up to date with main", "None"])
        #expect(ready.failedChecks.isEmpty && ready.notice == nil && ready.stageNote == nil)
    }

    @Test func theFailedPopoverListsTheFailedChecksWithTheirTimes() throws {
        let failed = content(try row(.checksFailed, in: stageRows()))
        #expect(failed.title == "#16 Native panel")
        #expect(failed.rows.map { text($0.parts) } == ["2 failed \u{00B7} 1 passed", "Review required", "Up to date with main", "None"])
        #expect(failed.rows[0].parts[0].failing)
        #expect(failed.failedChecks.map(\.name) == ["lint / swiftformat", "test / macos"])
        #expect(failed.failedChecks.map(\.duration) == ["0:42", "3:10"])
        #expect(failed.failedChecks.map(\.log) == [
            URL(string: "https://github.com/example/widgets/actions/runs/301/job/1"),
            URL(string: "https://github.com/example/widgets/actions/runs/302/job/2"),
        ])
        #expect(failed.secondary == [.rerunFailed, .openOnGitHub])
    }

    @Test func aDurationReadsAsMinutesAndSeconds() throws {
        var failed = try row(.checksFailed, in: stageRows())
        failed.pr?.failedChecks[0].duration = 0
        failed.pr?.failedChecks[1].duration = 3725
        let checks = content(failed).failedChecks
        // GitHub gives no time for a check that has none, so no time shows.
        #expect(checks.map(\.duration) == [nil, "1:02:05"])
    }

    @Test func aLogLinkNeedsAnHTTPSAddress() throws {
        var failed = try row(.checksFailed, in: stageRows())
        failed.pr?.failedChecks[0].url = "file:///etc/passwd"
        failed.pr?.failedChecks[1].url = ""
        #expect(content(failed).failedChecks.map(\.log) == [nil, nil])
    }

    @Test func aFailedChecksListWithNothingToRunAgainOffersNoRerun() throws {
        var failed = try row(.checksFailed, in: stageRows())
        // A failed check that is not a job of GitHub Actions has no run, and the core cannot run it again.
        for index in failed.pr?.failedChecks.indices ?? 0..<0 { failed.pr?.failedChecks[index].runID = nil }
        #expect(content(failed).secondary == [.openOnGitHub])
        failed.pr?.failedChecks[0].runID = 301
        #expect(content(failed).secondary == [.rerunFailed, .openOnGitHub])
    }

    @Test func updateBranchShowsOnlyWhenTheBranchIsBehind() throws {
        let rows = try stageRows()
        #expect(content(try row(.behindBase, in: rows)).secondary.contains(.updateBranch))
        var failed = try row(.checksFailed, in: rows)
        failed.pr?.behindBase = 2
        // A failed PR that is also behind: Update branch shows with Re-run failed.
        #expect(content(failed).secondary == [.rerunFailed, .updateBranch, .openOnGitHub])
        #expect(!content(try row(.readyToMerge, in: rows)).secondary.contains(.updateBranch))
    }

    @Test func theOptionalChecksOfAReadyPRShowAsFailedChecks() throws {
        let unstable = content(try #require(try stageRows().last))
        #expect(unstable.stage == .readyToMerge)
        #expect(unstable.rows.map { text($0.parts) }[0] == "2 optional failed \u{00B7} 2 passed")
        #expect(unstable.failedChecks.map(\.name) == ["lint / swiftlint", "docs / links"])
        #expect(unstable.secondary == [.rerunFailed, .openOnGitHub])
    }

    // MARK: Notes of a stage

    @Test func blockedSaysWhereToSeeWhy() throws {
        #expect(content(try row(.blocked, in: stageRows())).stageNote == "GitHub blocks the merge. Open it on GitHub to see why.")
    }

    @Test func aPRInTheMergeQueueSaysItsPlace() throws {
        #expect(content(try row(.inMergeQueue, in: stageRows())).stageNote == "Position 2 in the merge queue.")
    }

    @Test func otherStagesHaveNoNote() throws {
        let rows = try stageRows()
        let withNote = rows.filter { content($0).stageNote != nil }.map(\.stage)
        #expect(withNote == [.inMergeQueue, .blocked])
    }

    // MARK: The primary button

    /// README, "Stages", and ticket 109: Land… at Ready to merge, and Send failures, Send review or Send
    /// conflicts at the three stages that a session can fix. No other stage has a primary button.
    @Test func theRuleGivesAPrimaryButtonToFourStages() {
        let expected: [WorktreeStage: PRPrimaryAction] = [
            .readyToMerge: .land, .checksFailed: .sendFailures, .changesRequested: .sendReview, .conflicts: .sendConflicts,
        ]
        for stage in WorktreeStage.allCases {
            #expect(PRPrimaryAction(stage: stage) == expected[stage], "\(stage)")
        }
    }

    @Test func thePrimaryButtonsReadAsTheBoardsDo() {
        #expect(PRPrimaryAction.allCases.map(\.title) == [
            "Land\u{2026}", "Send failures to session", "Send review to session", "Send conflicts to session",
        ])
    }

    /// Tickets 110 and 112 build the buttons. Until then no stage shows one.
    @Test func noPrimaryButtonIsBuiltYet() throws {
        #expect(PRPrimaryAction.built.isEmpty)
        for status in try stageRows() { #expect(PRPopoverContent(status, now: sameDay, timeZone: utc).primary == nil) }
    }

    @Test func aBuiltButtonShowsAtItsStageOnly() throws {
        let rows = try stageRows()
        let all = Set(PRPrimaryAction.allCases)
        #expect(content(try row(.readyToMerge, in: rows), built: all).primary == .land)
        #expect(content(try row(.checksFailed, in: rows), built: all).primary == .sendFailures)
        #expect(content(try row(.changesRequested, in: rows), built: all).primary == .sendReview)
        #expect(content(try row(.conflicts, in: rows), built: all).primary == .sendConflicts)
        #expect(content(try row(.draft, in: rows), built: all).primary == nil)
        // A button whose ticket is not merged stays hidden, the others show.
        #expect(content(try row(.readyToMerge, in: rows), built: [.sendFailures]).primary == nil)
        #expect(content(try row(.checksFailed, in: rows), built: [.sendFailures]).primary == .sendFailures)
    }

    // MARK: The header

    @Test func theHeaderTimeIsTheTimeOfTheAnswerOfGitHub() throws {
        var status = try row(.readyToMerge, in: stageRows())
        status.prCheckedAt = "2026-01-01T10:02:00Z"
        #expect(content(status).updated == "Updated 10:02")
        status.prCheckedAt = nil
        #expect(content(status).updated == nil)
    }

    // MARK: Offline

    @Test func offlineSaysWhenGitHubFailedAndWhichStateThisIs() throws {
        var status = try row(.checksFailed, in: stageRows())
        status.prNote = .offline
        status.prCheckedAt = "2026-01-01T12:02:00Z"
        let popover = content(status, attemptedAt: later)
        #expect(popover.notice == "Loam could not reach GitHub at 12:14. This is the state from 12:02.")
        // The rows still show the last state.
        #expect(popover.stage == .checksFailed && popover.rows.count == 4)
    }

    @Test func aRateLimitReadsAsOffline() throws {
        var status = try row(.checksFailed, in: stageRows())
        status.prNote = .rateLimited
        status.prCheckedAt = "2026-01-01T12:02:00Z"
        #expect(content(status, attemptedAt: later).notice == "Loam could not reach GitHub at 12:14. This is the state from 12:02.")
    }

    @Test func offlineWithNoAnswerYetHasNoOldState() throws {
        var status = try row(.notPushed, in: stageRows())
        status.prNote = .offline
        status.prCheckedAt = nil
        #expect(content(status, attemptedAt: later).notice == "Loam could not reach GitHub at 12:14.")
    }

    @Test func offlineBeforeTheAppAskedLeavesTheAttemptOut() throws {
        var status = try row(.checksFailed, in: stageRows())
        status.prNote = .offline
        status.prCheckedAt = "2026-01-01T12:02:00Z"
        #expect(content(status).notice == "Loam could not reach GitHub. This is the state from 12:02.")
    }

    @Test func aRepoWithNoGitHubRemoteSaysSo() throws {
        var status = try row(.notPushed, in: stageRows())
        status.prNote = .noGitHubRemote
        let popover = content(status)
        #expect(popover.notice == "This repo has no GitHub remote.")
        #expect(popover.secondary == [.copyBranchName])
    }

    @Test func noOtherNoteAddsALine() throws {
        for note in [PRNote.noNote, .ghMissing, .ghSignedOut, .noAccess] {
            var status = try row(.checksFailed, in: stageRows())
            status.prNote = note
            #expect(content(status).notice == nil, "\(note)")
        }
    }

    // MARK: No PR

    /// Board 5.3, without the Goal and the Link that ticket 115 adds.
    @Test func aWorktreeWithNoPRShowsItsBaseAndItsLocalState() throws {
        var local = try row(.notPushed, in: stageRows())
        local.changed = 0
        local.unpushed = 4
        let popover = content(local)
        #expect(!popover.hasPullRequest && popover.stage == nil)
        #expect(popover.title == local.worktree.branch)
        #expect(popover.subtitle == "No pull request yet")
        #expect(popover.rows.map(\.label) == ["Base", "Local"])
        #expect(popover.rows.map { text($0.parts) } == ["origin/main", "4 commits not pushed"])
        // Not pushed: there is nothing on GitHub to open.
        #expect(popover.secondary == [.copyBranchName] && popover.githubPage == nil)
        #expect(popover.primary == nil && popover.failedChecks.isEmpty)
    }

    @Test func aPushedBranchOpensTheComparePage() throws {
        let pushed = content(try row(.pushedNoPR, in: stageRows()))
        #expect(pushed.rows.map { text($0.parts) } == ["origin/main", "Pushed, no PR"])
        #expect(pushed.secondary == [.openOnGitHub, .copyBranchName])
        #expect(pushed.githubPage == URL(string: "https://github.com/example/widgets/compare/main...pushed-only"))
    }

    @Test func theComparePageNeedsAnHTTPSAddress() throws {
        var pushed = try row(.pushedNoPR, in: stageRows())
        pushed.compareURL = "javascript:alert(1)"
        #expect(content(pushed).secondary == [.copyBranchName])
    }

    @Test func aWorktreeThatStartedOnAnExistingBranchHasNoBaseRow() throws {
        var local = try row(.notPushed, in: stageRows())
        local.worktree.base = ""
        #expect(content(local).rows.map(\.label) == ["Local"])
    }

    @Test func aGoneFolderSaysSoAndStillCopiesTheBranch() throws {
        var gone = try row(.notPushed, in: stageRows())
        gone.missing = true
        let popover = content(gone)
        #expect(popover.subtitle == "Folder is gone")
        #expect(popover.rows.map(\.label) == ["Base"])
        #expect(popover.secondary == [.copyBranchName])
    }

    @Test func theOpenAddressOfAPRIsItsPage() throws {
        let ready = content(try row(.readyToMerge, in: stageRows()))
        #expect(ready.githubPage == URL(string: "https://github.com/example/widgets/pull/22"))
    }

    @Test func everyButtonHasAWordForTheScreenAndAnIdentifier() {
        let all: [PRSecondaryAction] = [.rerunFailed, .updateBranch, .openOnGitHub, .copyBranchName]
        #expect(all.map(\.title) == ["Re-run failed", "Update branch", "Open on GitHub", "Copy branch name"])
        #expect(Set(all.map(\.rawValue)).count == 4)
    }
}

// MARK: What a button did

@Suite struct PRActionNoteTests {
    private func rerun(_ runs: [FailedRun], skipped: [String] = []) throws -> RerunResult {
        var result = try JSONDecoder().decode(RerunResult.self, from: Fixtures.data("worktree_rerun"))
        result.runs = runs
        result.skippedChecks = skipped
        return result
    }

    @Test func theRerunNamesTheRunsThatStartedAndWhyOthersDidNot() throws {
        let both = try JSONDecoder().decode(RerunResult.self, from: Fixtures.data("worktree_rerun"))
        let note = PRActionNote.rerun(both)
        #expect(note.hasPrefix("GitHub runs the failed checks of 1 run again. Could not re-run the run 302: "))
    }

    @Test func theRerunCountsTheRuns() throws {
        #expect(PRActionNote.rerun(try rerun([FailedRun(id: 1, started: true), FailedRun(id: 2, started: true)]))
                == "GitHub runs the failed checks of 2 runs again.")
        #expect(PRActionNote.rerun(try rerun([])) == "GitHub did not run any check again.")
    }

    @Test func aRunWithNoReasonStillGetsAWord() throws {
        #expect(PRActionNote.rerun(try rerun([FailedRun(id: 7, started: false)]))
                == "GitHub did not run any check again. GitHub did not start the run 7.")
    }

    @Test func theChecksThatAreNoJobsOfGitHubActionsAreNamed() throws {
        #expect(PRActionNote.rerun(try rerun([FailedRun(id: 1, started: true)], skipped: ["ci/legacy", "ci/other"]))
                == "GitHub runs the failed checks of 1 run again. Loam cannot run these failed checks again: ci/legacy, ci/other.")
    }

    @Test func theUpdateNamesTheBase() throws {
        let result = try JSONDecoder().decode(UpdateResult.self, from: Fixtures.data("worktree_update"))
        #expect(PRActionNote.update(result) == "GitHub brought the PR up to date with main.")
    }

    @Test func aFetchThatFailedIsPartOfTheNote() throws {
        var result = try JSONDecoder().decode(UpdateResult.self, from: Fixtures.data("worktree_update"))
        result.fetched = false
        #expect(PRActionNote.update(result) == "GitHub brought the PR up to date with main. Loam could not fetch the new commits.")
        result.fetchNote = "no network"
        #expect(PRActionNote.update(result) == "GitHub brought the PR up to date with main. Loam could not fetch the new commits: no network")
    }
}

// MARK: Where the popover goes

@Suite struct PopoverPlacementTests {
    let container = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let size = CGSize(width: 360, height: 300)

    @Test func itOpensBelowTheAnchorWhenThereIsRoom() {
        let anchor = CGRect(x: 100, y: 100, width: 40, height: 20)
        let frame = PopoverPlacement.frame(size: size, anchor: anchor, in: container)
        #expect(frame.origin == CGPoint(x: 100, y: 100 + 20 + PopoverPlacement.gap))
        #expect(frame.size == size)
    }

    /// The action bar chip is at the bottom of the window.
    @Test func itOpensAboveTheAnchorWhenBelowHasNoRoom() {
        let anchor = CGRect(x: 120, y: 660, width: 60, height: 24)
        let frame = PopoverPlacement.frame(size: size, anchor: anchor, in: container)
        #expect(frame.maxY == 660 - PopoverPlacement.gap)
        #expect(frame.minX == 120)
    }

    @Test func itStaysInsideTheContainerAtTheTrailingEdge() {
        let anchor = CGRect(x: 900, y: 100, width: 80, height: 28)
        let frame = PopoverPlacement.frame(size: size, anchor: anchor, in: container)
        #expect(frame.maxX == container.maxX - PopoverPlacement.margin)
        #expect(frame.minX == 1000 - PopoverPlacement.margin - 360)
    }

    @Test func itStaysInsideTheContainerAtTheLeadingEdge() {
        let anchor = CGRect(x: -20, y: 100, width: 10, height: 20)
        #expect(PopoverPlacement.frame(size: size, anchor: anchor, in: container).minX == PopoverPlacement.margin)
    }

    @Test func aPopoverTallerThanEitherSideTakesTheSideWithMoreRoom() {
        let tall = CGSize(width: 360, height: 650)
        let high = PopoverPlacement.frame(size: tall, anchor: CGRect(x: 100, y: 200, width: 40, height: 20), in: container)
        // More room below: the popover starts under the anchor and ends at the margin.
        #expect(high.maxY <= container.maxY - PopoverPlacement.margin)
        let low = PopoverPlacement.frame(size: tall, anchor: CGRect(x: 100, y: 500, width: 40, height: 20), in: container)
        #expect(low.minY >= container.minY + PopoverPlacement.margin)
    }
}
