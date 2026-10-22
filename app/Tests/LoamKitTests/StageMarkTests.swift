import Foundation
import Testing

@testable import LoamKit

/// Ticket 107: the stage table in one place, and the mark that a worktree row of the sidebar shows.
/// The worktrees come from the `worktree_list_stages` fixture: one made-up worktree for each stage
/// (example/widgets, PRs 11 to 24), then a second Ready to merge whose optional checks failed.
/// The tooltip is the PR number, the stage in words, and the status line of the Worktrees section (ticket 108).
@Suite struct StageMarkTests {
    /// The fixture times are 2026-01-01T00:00:00Z. This is the same day, in UTC.
    let utc = TimeZone(identifier: "UTC")!
    let sameDay = ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z")!

    /// The mark of a worktree, with a fixed clock and time zone, so a merge time reads the same anywhere.
    func shown(_ status: WorktreeStatus) -> StageMark? {
        StageMark(status, now: sameDay, timeZone: utc)
    }

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

    /// The ✎ is text. It follows the size of the symbols next to it: one point smaller, which is the
    /// sidebar as it was (a 12 pt symbol, and the ✎ at the 11 pt of the caption style), and a 12 pt ✎
    /// in the 13 pt symbol of the Worktrees section.
    @Test func thePencilFollowsTheSizeOfTheSymbolsNextToIt() {
        #expect(WorktreeStage.pencilSize(symbolSize: 12) == LoamTheme.captionStyle.size)
        #expect(WorktreeStage.pencilSize(symbolSize: 13) == 12)
        #expect(WorktreeStage.pencilSize(symbolSize: 16) > WorktreeStage.pencilSize(symbolSize: 13))
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

    /// The number, the symbol, the colour token, and the tooltip of each stage. The tooltip is the number,
    /// the stage in words, and the status line of the stage (README, "Stages"). A part of the line that
    /// repeats the stage words is left out.
    @Test func eachStageShowsTheNumberTheSymbolTheColourAndTheTooltip() throws {
        let list = try listed()
        let expected: [(WorktreeStage, Int, String)] = [
            (.merged, 11, "#11 \u{00B7} Merged \u{00B7} Merged 00:00"),
            (.closed, 12, "#12 \u{00B7} Closed \u{00B7} Closed without a merge"),
            (.inMergeQueue, 13, "#13 \u{00B7} In merge queue \u{00B7} Position 2 in the merge queue"),
            (.conflicts, 14, "#14 \u{00B7} Conflicts \u{00B7} Conflicts with main"),
            (.changesRequested, 15, "#15 \u{00B7} Changes requested \u{00B7} 3 comments"),
            (.checksFailed, 16, "#16 \u{00B7} Checks failed \u{00B7} 2 of 3 checks failed"),
            (.approvalNeeded, 17, "#17 \u{00B7} Approval needed \u{00B7} 1 workflow waits for approval"),
            (.draft, 21, "#21 \u{00B7} Draft \u{00B7} 1 of 1 check done"),
            (.behindBase, 18, "#18 \u{00B7} Behind base \u{00B7} 3 commits behind main"),
            (.checksRunning, 19, "#19 \u{00B7} Checks running \u{00B7} 1 of 2 checks done"),
            (.waitingForReview, 20, "#20 \u{00B7} Waiting for review \u{00B7} Review required"),
            (.blocked, 23, "#23 \u{00B7} Blocked \u{00B7} GitHub blocks the merge"),
            (.readyToMerge, 22, "#22 \u{00B7} Ready to merge \u{00B7} 1 of 1 check passed \u{00B7} Approved"),
        ]
        for (stage, number, tooltip) in expected {
            let mark = try #require(shown(status(stage, in: list)), "\(stage)")
            #expect(mark.stage == stage)
            #expect(mark.number == number, "\(stage)")
            #expect(mark.symbol == stage.symbol && mark.symbol != nil, "\(stage)")
            #expect(mark.tone == stage.tone, "\(stage)")
            #expect(mark.tooltip == tooltip, "\(stage)")
        }
    }

    /// The sidebar tooltip and the spoken form say the number, the stage in words, and then the words of
    /// the status line of the Worktrees section for the same worktree. `StatusLine` is the only place
    /// that writes the line. A part of the line that repeats the stage words is left out.
    @Test func theTooltipSaysTheStageAndTheWordsOfTheStatusLine() throws {
        for status in try listed() where status.pr != nil {
            let stage = try #require(status.stage)
            let line = StatusLine(of: status, now: sameDay, timeZone: utc)
            let mark = try #require(shown(status))
            let number = try #require(status.pr?.number)
            let words = ["#\(number)", stage.words] + line.parts.map(\.text).filter { $0 != stage.words }
            #expect(mark.tooltip == words.joined(separator: " \u{00B7} "), "\(stage)")
            #expect(mark.spoken == words.joined(separator: ", "), "\(stage)")
            #expect(mark.tooltip?.hasPrefix("#\(number) \u{00B7} \(stage.words)") == true, "\(stage)")
        }
    }

    /// A status line that is empty, or the same words as the stage, adds nothing: the tooltip ends with the stage.
    @Test func aLineThatRepeatsTheStageWordsIsLeftOut() throws {
        var draft = try status(.draft, in: listed())
        draft.pr?.checks.total = 0
        #expect(StatusLine(of: draft).text == "Draft")
        #expect(shown(draft)?.tooltip == "#21 \u{00B7} Draft")
        #expect(shown(draft)?.spoken == "#21, Draft")

        var changes = try status(.changesRequested, in: listed())
        changes.pr?.comments = 0
        #expect(shown(changes)?.tooltip == "#15 \u{00B7} Changes requested")

        var ready = try status(.readyToMerge, in: listed())
        ready.pr?.checks.total = 0
        ready.pr?.reviewDecision = ""
        #expect(StatusLine(of: ready).text == "Ready to merge")
        #expect(shown(ready)?.tooltip == "#22 \u{00B7} Ready to merge")
        #expect(shown(ready)?.spoken == "#22, Ready to merge")
    }

    /// A line of two parts that starts with the stage words says them once.
    @Test func aPartThatRepeatsTheStageWordsIsLeftOutOfALongerLine() throws {
        let draft = try status(.draft, in: listed())
        #expect(StatusLine(of: draft).text == "Draft \u{00B7} 1 of 1 check done")
        #expect(shown(draft)?.tooltip == "#21 \u{00B7} Draft \u{00B7} 1 of 1 check done")
        #expect(shown(draft)?.spoken == "#21, Draft, 1 of 1 check done")
    }

    /// The clock and the time zone of the mark give the merge time, as the status line does.
    @Test func aMergeTimeFollowsTheClockAndTheTimeZone() throws {
        let merged = try status(.merged, in: listed())
        let later = ISO8601DateFormatter().date(from: "2026-01-05T12:00:00Z")!
        #expect(StageMark(merged, now: later, timeZone: utc)?.tooltip == "#11 \u{00B7} Merged \u{00B7} Merged 1 Jan, 00:00")
        let plusTwo = TimeZone(secondsFromGMT: 2 * 3600)!
        #expect(StageMark(merged, now: sameDay, timeZone: plusTwo)?.tooltip == "#11 \u{00B7} Merged \u{00B7} Merged 02:00")
    }

    @Test func theNumberReadsAsHashAndTheDigits() throws {
        let mark = try #require(shown(status(.checksFailed, in: listed())))
        #expect(mark.label == "#16")
    }

    @Test func aMergedAndAClosedPRShowTheirSymbolInFaintInk() throws {
        let list = try listed()
        for stage in [WorktreeStage.merged, .closed] {
            let mark = try #require(shown(status(stage, in: list)))
            #expect(mark.label != nil && mark.tone == .inkFaint, "\(stage)")
        }
    }

    /// "2 of 2 required checks passed · 2 optional failed": GitHub allows the merge, and the count is of the required checks.
    @Test func readyToMergeWithOptionalChecksThatFailedSaysSo() throws {
        let unstable = try #require(listed().last)
        #expect(unstable.stage == .readyToMerge && unstable.pr?.checks.passed == 2 && unstable.pr?.checks.total == 4)
        #expect(shown(unstable)?.tooltip == "#24 · Ready to merge · 2 of 2 required checks passed · 2 optional failed")
    }

    @Test func readyToMergeCountsAllChecksWhenAllOfThemPassed() throws {
        var ready = try status(.readyToMerge, in: listed())
        ready.pr?.checks.required = 0
        ready.pr?.checks.total = 14
        ready.pr?.checks.passed = 14
        #expect(shown(ready)?.tooltip == "#22 · Ready to merge · 14 of 14 checks passed · Approved")
        ready.pr?.checks.required = 14
        ready.pr?.checks.requiredPassed = 14
        #expect(shown(ready)?.tooltip == "#22 · Ready to merge · 14 of 14 checks passed · Approved")
    }

    @Test func aPRWithNoChecksHasNoCount() throws {
        var failed = try status(.checksFailed, in: listed())
        failed.pr?.checks.total = 0
        failed.pr?.checks.failed = 0
        #expect(shown(failed)?.tooltip == "#16 · Checks failed")
        var running = try status(.checksRunning, in: listed())
        running.pr?.checks.total = 0
        #expect(shown(running)?.tooltip == "#19 · Checks running · Waiting for checks")
    }

    @Test func checksRunningCountsTheChecksThatAreDone() throws {
        var running = try status(.checksRunning, in: listed())
        running.pr?.checks.total = 14
        running.pr?.checks.running = 4
        running.pr?.checks.waiting = 1
        #expect(shown(running)?.tooltip == "#19 · Checks running · 9 of 14 checks done")
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
            let mark = try #require(shown(checking), "state \"\(state)\"")
            #expect(mark.stage == .checksRunning && mark.symbol == WorktreeStage.checksRunning.symbol, "state \"\(state)\"")
            #expect(mark.tooltip == "#19 · Checks running · Checking…", "state \"\(state)\"")
            #expect(mark.spoken == "#19, Checks running, Checking…", "state \"\(state)\"")
        }
        // Checks that all passed give no count either.
        var passed = try status(.checksRunning, in: listed())
        passed.pr?.checks = PRCheckCounts(state: "SUCCESS", total: 3, passed: 3, failed: 0, running: 0, waiting: 0,
                                          required: 3, requiredPassed: 3)
        #expect(shown(passed)?.tooltip == "#19 · Checks running · Checking…")
        // No checks at all.
        var none = try status(.checksRunning, in: listed())
        none.pr?.checks = PRCheckCounts(state: "", total: 0, passed: 0, failed: 0, running: 0, waiting: 0,
                                        required: 0, requiredPassed: 0)
        #expect(shown(none)?.tooltip == "#19 · Checks running · Checking…")
    }

    /// A summary of PENDING or EXPECTED, a check that runs, or a check that waits keeps the count and does
    /// not say "Checking…".
    @Test func checksRunningWithAnActiveCheckKeepsItsCount() throws {
        for state in ["PENDING", "EXPECTED"] {
            var running = try status(.checksRunning, in: listed())
            running.pr?.checks.running = 0
            running.pr?.checks.state = state
            #expect(shown(running)?.tooltip == "#19 · Checks running · 2 of 2 checks done", "state \(state)")
        }
        var running = try status(.checksRunning, in: listed())
        running.pr?.checks.running = 1
        running.pr?.checks.state = "SUCCESS"
        #expect(shown(running)?.tooltip == "#19 · Checks running · 1 of 2 checks done")
        var waiting = try status(.checksRunning, in: listed())
        waiting.pr?.checks.running = 0
        waiting.pr?.checks.waiting = 1
        waiting.pr?.checks.state = "SUCCESS"
        #expect(shown(waiting)?.tooltip == "#19 · Checks running · 1 of 2 checks done")
    }

    @Test func theSpokenFormUsesCommasAndTheTooltipUsesDots() throws {
        let mark = try #require(shown(status(.checksFailed, in: listed())))
        #expect(mark.tooltip == "#16 · Checks failed · 2 of 3 checks failed")
        #expect(mark.spoken == "#16, Checks failed, 2 of 3 checks failed")
    }

    // MARK: A worktree with no PR

    @Test func withNoPRAChangedFileKeepsThePencil() throws {
        let mark = try #require(shown(local(changed: 2)))
        #expect(mark.stage == .notPushed && mark.number == nil && mark.label == nil)
        #expect(mark.symbol == nil && mark.tone == .inkMuted)
        #expect(mark.tooltip == nil && mark.spoken == "Not pushed")
    }

    @Test func withNoPRAnUnpushedCommitKeepsThePencil() throws {
        #expect(try shown(local(unpushed: 1))?.stage == .notPushed)
    }

    @Test func withNoPRAndNoLocalWorkThereIsNoMark() throws {
        #expect(try shown(local()) == nil)
        // Pushed, no PR has a symbol in the table, but the sidebar shows a mark only for a PR.
        #expect(try shown(status(.pushedNoPR, in: listed())) == nil)
    }

    /// A pushed branch with local work shows the pencil as before: removal would still lose the work.
    @Test func aPushedBranchWithLocalWorkKeepsThePencil() throws {
        #expect(try shown(local(changed: 1, stage: .pushedNoPR))?.stage == .notPushed)
    }

    /// New work after a merged PR: the core sends no PR and a local stage.
    @Test func newWorkAfterAMergeShowsThePencilNotTheMergedMark() throws {
        let mark = try #require(shown(local(unpushed: 2, stage: .notPushed)))
        #expect(mark.stage == .notPushed && mark.number == nil)
    }

    // MARK: Other states

    @Test func aWorktreeWhoseFolderIsGoneHasNoMark() throws {
        var gone = try status(.readyToMerge, in: listed())
        gone.missing = true
        #expect(shown(gone) == nil)
        #expect(try shown(local(changed: 1, missing: true)) == nil)
    }

    /// A core without ship state sends no stage and no PR. The row shows what it showed before.
    @Test func aCoreWithoutShipStateKeepsThePencil() throws {
        var old = try local(changed: 1)
        old.stage = nil
        old.pr = nil
        #expect(shown(old)?.stage == .notPushed)
        old.changed = 0
        #expect(shown(old) == nil)
    }

    /// A PR with no stage cannot come from the core. The row still shows the local mark.
    @Test func aPRWithNoStageFallsBackToTheLocalMark() throws {
        var odd = try status(.readyToMerge, in: listed())
        odd.stage = .noStage
        odd.changed = 1
        #expect(shown(odd)?.stage == .notPushed)
        odd.changed = 0
        #expect(shown(odd) == nil)
    }

    /// The last answer stays while GitHub cannot be reached: the mark shows it.
    @Test func anOldAnswerStillShowsWhileGitHubIsOffline() throws {
        for note in [PRNote.offline, .rateLimited, .noAccess] {
            var old = try status(.checksFailed, in: listed())
            old.prNote = note
            #expect(shown(old)?.stage == .checksFailed, "\(note)")
            #expect(shown(old)?.tooltip == "#16 · Checks failed · 2 of 3 checks failed", "\(note)")
        }
    }
}
