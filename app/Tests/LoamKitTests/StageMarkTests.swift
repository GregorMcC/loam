import Foundation
import Testing

@testable import LoamKit

/// Ticket 107: the stage table in one place, and the mark that a worktree row of the sidebar shows.
/// The worktrees come from the `worktree_list_stages` fixture: one made-up worktree for each stage
/// (example/widgets, PRs 11 to 24), then a second Ready to merge whose optional checks failed.
@Suite struct StageMarkTests {
    func listed() throws -> [WorktreeStatus] {
        try JSONDecoder().decode([WorktreeStatus].self, from: Fixtures.data("worktree_list_stages"))
    }

    func status(_ stage: WorktreeStage, in list: [WorktreeStatus]) throws -> WorktreeStatus {
        try #require(list.first { $0.stage == stage })
    }

    /// A worktree with no PR and the given local state.
    func local(changed: Int = 0, unpushed: Int = 0, stage: WorktreeStage? = nil, missing: Bool = false) throws -> WorktreeStatus {
        var status = try #require(listed().first { $0.stage == .notPushed })
        status.changed = changed
        status.unpushed = unpushed
        status.stage = stage
        status.missing = missing
        return status
    }

    // MARK: The table

    /// The ship-state README, "Stages": symbol, colour token, and name of each stage.
    @Test func theTableHoldsTheSymbolTheColourAndTheWordsOfEachStage() {
        let table: [(WorktreeStage, String?, StageTone, String)] = [
            (.merged, "arrow.triangle.merge", .inkFaint, "Merged"),
            (.closed, "slash.circle", .inkFaint, "Closed"),
            (.inMergeQueue, "list.number", .inkMuted, "In merge queue"),
            (.conflicts, "exclamationmark.triangle", .rust, "Conflicts"),
            (.changesRequested, "text.bubble", .inkMuted, "Changes requested"),
            (.checksFailed, "xmark.circle", .rust, "Checks failed"),
            (.approvalNeeded, "hand.raised", .inkMuted, "Approval needed"),
            (.draft, "circle.dotted", .inkFaint, "Draft"),
            (.behindBase, "arrow.down.circle", .inkMuted, "Behind base"),
            (.checksRunning, "circle.dashed", .inkMuted, "Checks running"),
            (.waitingForReview, "eye", .inkMuted, "Waiting for review"),
            (.blocked, "lock", .inkMuted, "Blocked"),
            (.readyToMerge, "checkmark.circle", .ink, "Ready to merge"),
            (.pushedNoPR, "arrow.up.circle", .inkFaint, "Pushed, no PR"),
            // Not pushed keeps the ✎ mark, which is text and not an SF Symbol.
            (.notPushed, nil, .inkMuted, "Not pushed"),
        ]
        #expect(table.map(\.0) == WorktreeStage.allCases.filter { $0 != .noStage })
        for (stage, symbol, tone, words) in table {
            #expect(stage.symbol == symbol, "\(stage)")
            #expect(stage.tone == tone, "\(stage)")
            #expect(stage.words == words, "\(stage)")
        }
        #expect(WorktreeStage.noStage.symbol == nil && WorktreeStage.noStage.words == "")
    }

    @Test func onlyConflictsAndChecksFailedTakeRust() {
        let rust = WorktreeStage.allCases.filter { $0.tone == .rust }
        #expect(rust == [.conflicts, .checksFailed])
    }

    /// The app reads a stage colour by its token name, from the colours that follow the terminal theme.
    @Test func theToneNamesAreTokensOfTheTheme() {
        let tokens = Set(LoamTheme.colorTokens.map(\.name))
        for tone in [StageTone.ink, .inkMuted, .inkFaint, .rust] {
            #expect(tokens.contains(tone.rawValue) && ChromeSurfaces.tokenNames.contains(tone.rawValue), "\(tone)")
        }
    }

    @Test func onlyAStageFromAPullRequestHasANumber() {
        let fromGit = WorktreeStage.allCases.filter { !$0.comesFromPullRequest }
        #expect(fromGit == [.pushedNoPR, .notPushed, .noStage])
    }

    // MARK: A worktree with a PR

    /// The number, the symbol, the colour token, and the tooltip of each stage. The tooltip adds the
    /// check count to the stages that the README gives one.
    @Test func eachStageShowsTheNumberTheSymbolTheColourAndTheTooltip() throws {
        let list = try listed()
        let expected: [(WorktreeStage, Int, String)] = [
            (.merged, 11, "#11 · Merged"),
            (.closed, 12, "#12 · Closed"),
            (.inMergeQueue, 13, "#13 · In merge queue"),
            (.conflicts, 14, "#14 · Conflicts"),
            (.changesRequested, 15, "#15 · Changes requested"),
            (.checksFailed, 16, "#16 · Checks failed · 2 of 3"),
            (.approvalNeeded, 17, "#17 · Approval needed"),
            (.draft, 21, "#21 · Draft"),
            (.behindBase, 18, "#18 · Behind base"),
            (.checksRunning, 19, "#19 · Checks running · 1 of 2"),
            (.waitingForReview, 20, "#20 · Waiting for review"),
            (.blocked, 23, "#23 · Blocked"),
            (.readyToMerge, 22, "#22 · Ready to merge · 1 of 1"),
        ]
        for (stage, number, tooltip) in expected {
            let mark = try #require(StageMark(status(stage, in: list)), "\(stage)")
            #expect(mark.stage == stage)
            #expect(mark.number == number, "\(stage)")
            #expect(mark.symbol == stage.symbol && mark.symbol != nil, "\(stage)")
            #expect(mark.tone == stage.tone, "\(stage)")
            #expect(mark.tooltip == tooltip, "\(stage)")
        }
    }

    @Test func theNumberReadsAsHashAndTheDigits() throws {
        let mark = try #require(StageMark(status(.checksFailed, in: listed())))
        #expect(mark.label == "#16")
    }

    @Test func aMergedAndAClosedPRShowTheirSymbolInFaintInk() throws {
        let list = try listed()
        for stage in [WorktreeStage.merged, .closed] {
            let mark = try #require(StageMark(status(stage, in: list)))
            #expect(mark.label != nil && mark.tone == .inkFaint, "\(stage)")
        }
    }

    /// "14 of 14 required checks passed · 2 optional failed": the count is of the required checks.
    @Test func readyToMergeCountsTheRequiredChecksWhenThereAreSome() throws {
        let unstable = try #require(listed().last)
        #expect(unstable.stage == .readyToMerge && unstable.pr?.checks.passed == 2 && unstable.pr?.checks.total == 4)
        #expect(StageMark(unstable)?.tooltip == "#24 · Ready to merge · 2 of 2")
    }

    @Test func readyToMergeCountsAllChecksWhenNoneIsRequired() throws {
        var ready = try status(.readyToMerge, in: listed())
        ready.pr?.checks.required = 0
        ready.pr?.checks.total = 14
        ready.pr?.checks.passed = 14
        #expect(StageMark(ready)?.tooltip == "#22 · Ready to merge · 14 of 14")
        ready.pr?.checks.required = nil
        #expect(StageMark(ready)?.tooltip == "#22 · Ready to merge · 14 of 14")
    }

    @Test func aPRWithNoChecksHasNoCount() throws {
        var failed = try status(.checksFailed, in: listed())
        failed.pr?.checks.total = 0
        failed.pr?.checks.failed = 0
        #expect(StageMark(failed)?.tooltip == "#16 · Checks failed")
        var running = try status(.checksRunning, in: listed())
        running.pr?.checks.total = 0
        #expect(StageMark(running)?.tooltip == "#19 · Checks running")
    }

    @Test func checksRunningCountsTheChecksThatAreDone() throws {
        var running = try status(.checksRunning, in: listed())
        running.pr?.checks.total = 14
        running.pr?.checks.running = 4
        running.pr?.checks.waiting = 1
        #expect(StageMark(running)?.tooltip == "#19 · Checks running · 9 of 14")
    }

    /// GitHub has not finished its merge check (mergeable UNKNOWN) and no check runs or waits: the core
    /// gives Checks running, and the README row says "Checking…" with no count.
    @Test func checksRunningWithNoCheckRunningSaysCheckingAndHasNoCount() throws {
        for state in ["", "SUCCESS", "FAILURE"] {
            var checking = try status(.checksRunning, in: listed())
            checking.pr?.mergeable = "UNKNOWN"
            checking.pr?.checks.running = 0
            checking.pr?.checks.waiting = 0
            checking.pr?.checks.state = state
            let mark = try #require(StageMark(checking), "state \"\(state)\"")
            #expect(mark.stage == .checksRunning && mark.symbol == WorktreeStage.checksRunning.symbol, "state \"\(state)\"")
            #expect(mark.tooltip == "#19 · Checking…", "state \"\(state)\"")
            #expect(mark.spoken == "#19, Checking…", "state \"\(state)\"")
        }
        // Checks that all passed give no count either.
        var passed = try status(.checksRunning, in: listed())
        passed.pr?.checks = PRCheckCounts(state: "SUCCESS", total: 3, passed: 3, failed: 0, running: 0, waiting: 0,
                                          required: 3, requiredPassed: 3)
        #expect(StageMark(passed)?.tooltip == "#19 · Checking…")
        // No checks at all.
        var none = try status(.checksRunning, in: listed())
        none.pr?.checks = PRCheckCounts(state: "", total: 0, passed: 0, failed: 0, running: 0, waiting: 0,
                                        required: 0, requiredPassed: 0)
        #expect(StageMark(none)?.tooltip == "#19 · Checking…")
    }

    /// A summary of PENDING or EXPECTED, a check that runs, or a check that waits keeps the words and the count.
    @Test func checksRunningWithAnActiveCheckKeepsItsWordsAndCount() throws {
        for state in ["PENDING", "EXPECTED"] {
            var running = try status(.checksRunning, in: listed())
            running.pr?.checks.running = 0
            running.pr?.checks.state = state
            #expect(StageMark(running)?.tooltip?.hasPrefix("#19 · Checks running · ") == true, "state \(state)")
        }
        var running = try status(.checksRunning, in: listed())
        running.pr?.checks.running = 1
        running.pr?.checks.state = "SUCCESS"
        #expect(StageMark(running)?.tooltip == "#19 · Checks running · 1 of 2")
        var waiting = try status(.checksRunning, in: listed())
        waiting.pr?.checks.running = 0
        waiting.pr?.checks.waiting = 1
        waiting.pr?.checks.state = "SUCCESS"
        #expect(StageMark(waiting)?.tooltip == "#19 · Checks running · 1 of 2")
    }

    @Test func theSpokenFormUsesCommasAndTheTooltipUsesDots() throws {
        let mark = try #require(StageMark(status(.checksFailed, in: listed())))
        #expect(mark.tooltip == "#16 · Checks failed · 2 of 3")
        #expect(mark.spoken == "#16, Checks failed, 2 of 3")
    }

    // MARK: A worktree with no PR

    @Test func withNoPRAChangedFileKeepsThePencil() throws {
        let mark = try #require(StageMark(local(changed: 2)))
        #expect(mark.stage == .notPushed && mark.number == nil && mark.label == nil)
        #expect(mark.symbol == nil && mark.tone == .inkMuted)
        #expect(mark.tooltip == nil && mark.spoken == "Not pushed")
    }

    @Test func withNoPRAnUnpushedCommitKeepsThePencil() throws {
        #expect(try StageMark(local(unpushed: 1))?.stage == .notPushed)
    }

    @Test func withNoPRAndNoLocalWorkThereIsNoMark() throws {
        #expect(try StageMark(local()) == nil)
        // Pushed, no PR has a symbol in the table, but the sidebar shows a mark only for a PR.
        #expect(try StageMark(status(.pushedNoPR, in: listed())) == nil)
    }

    /// A pushed branch with local work shows the pencil as before: removal would still lose the work.
    @Test func aPushedBranchWithLocalWorkKeepsThePencil() throws {
        #expect(try StageMark(local(changed: 1, stage: .pushedNoPR))?.stage == .notPushed)
    }

    /// New work after a merged PR: the core sends no PR and a local stage.
    @Test func newWorkAfterAMergeShowsThePencilNotTheMergedMark() throws {
        let mark = try #require(StageMark(local(unpushed: 2, stage: .notPushed)))
        #expect(mark.stage == .notPushed && mark.number == nil)
    }

    // MARK: Other states

    @Test func aWorktreeWhoseFolderIsGoneHasNoMark() throws {
        var gone = try status(.readyToMerge, in: listed())
        gone.missing = true
        #expect(StageMark(gone) == nil)
        #expect(try StageMark(local(changed: 1, missing: true)) == nil)
    }

    /// A core without ship state sends no stage and no PR. The row shows what it showed before.
    @Test func aCoreWithoutShipStateKeepsThePencil() throws {
        var old = try local(changed: 1)
        old.stage = nil
        old.pr = nil
        #expect(StageMark(old)?.stage == .notPushed)
        old.changed = 0
        #expect(StageMark(old) == nil)
    }

    /// A PR with no stage cannot come from the core. The row still shows the local mark.
    @Test func aPRWithNoStageFallsBackToTheLocalMark() throws {
        var odd = try status(.readyToMerge, in: listed())
        odd.stage = .noStage
        odd.changed = 1
        #expect(StageMark(odd)?.stage == .notPushed)
        odd.changed = 0
        #expect(StageMark(odd) == nil)
    }

    /// The last answer stays while GitHub cannot be reached: the mark shows it.
    @Test func anOldAnswerStillShowsWhileGitHubIsOffline() throws {
        for note in [PRNote.offline, .rateLimited, .noAccess] {
            var old = try status(.checksFailed, in: listed())
            old.prNote = note
            #expect(StageMark(old)?.stage == .checksFailed, "\(note)")
            #expect(StageMark(old)?.tooltip == "#16 · Checks failed · 2 of 3", "\(note)")
        }
    }
}
