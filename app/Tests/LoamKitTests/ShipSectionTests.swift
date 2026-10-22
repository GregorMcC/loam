import Foundation
import Testing

@testable import LoamKit

/// The fixture `worktree_list_stages`: one worktree for each stage, in the order of the rule, then
/// a second Ready to merge whose optional checks failed.
private func stageRows() throws -> [WorktreeStatus] {
    try JSONDecoder().decode([WorktreeStatus].self, from: Fixtures.data("worktree_list_stages"))
}

private func row(_ stage: WorktreeStage, in rows: [WorktreeStatus]) throws -> WorktreeStatus {
    try #require(rows.first { $0.stage == stage })
}

private let utc = TimeZone(identifier: "UTC")!
/// The fixture times are 2026-01-01T00:00:00Z. This is the same day.
private let sameDay = ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z")!

private func line(_ status: WorktreeStatus, now: Date = sameDay) -> StatusLine {
    StatusLine(of: status, now: now, timeZone: utc)
}

@Suite struct StageTableTests {
    @Test func everyStageButNoneHasOneGlyph() {
        let stages = WorktreeStage.allCases.filter { $0 != .noStage }
        let glyphs = stages.compactMap(\.glyph)
        #expect(glyphs.count == stages.count)
        #expect(Set(glyphs.map { "\($0)" }).count == stages.count)
        #expect(WorktreeStage.noStage.glyph == nil)
    }

    @Test func theGlyphsAndTonesFollowTheStageTable() {
        let table: [(WorktreeStage, StageGlyph, StageTone, String)] = [
            (.merged, .symbol("arrow.triangle.merge"), .inkFaint, "Merged"),
            (.closed, .symbol("slash.circle"), .inkFaint, "Closed"),
            (.inMergeQueue, .symbol("list.number"), .inkMuted, "In merge queue"),
            (.conflicts, .symbol("exclamationmark.triangle"), .rust, "Conflicts"),
            (.changesRequested, .symbol("text.bubble"), .inkMuted, "Changes requested"),
            (.checksFailed, .symbol("xmark.circle"), .rust, "Checks failed"),
            (.approvalNeeded, .symbol("hand.raised"), .inkMuted, "Approval needed"),
            (.draft, .symbol("circle.dotted"), .inkFaint, "Draft"),
            (.behindBase, .symbol("arrow.down.circle"), .inkMuted, "Behind base"),
            (.checksRunning, .symbol("circle.dashed"), .inkMuted, "Checks running"),
            (.waitingForReview, .symbol("eye"), .inkMuted, "Waiting for review"),
            (.blocked, .symbol("lock"), .inkMuted, "Blocked"),
            (.readyToMerge, .symbol("checkmark.circle"), .ink, "Ready to merge"),
            (.pushedNoPR, .symbol("arrow.up.circle"), .inkFaint, "Pushed, no PR"),
            (.notPushed, .text("\u{270E}"), .inkMuted, "Not pushed"),
        ]
        #expect(table.map(\.0) == WorktreeStage.allCases.filter { $0 != .noStage })
        for (stage, glyph, tone, title) in table {
            #expect(stage.glyph == glyph, "\(stage) glyph")
            #expect(stage.tone == tone, "\(stage) tone")
            #expect(stage.title == title, "\(stage) title")
        }
    }

    @Test func onlyConflictsAndChecksFailedTakeRust() {
        let rust = WorktreeStage.allCases.filter { $0.tone == .rust }
        #expect(rust == [.conflicts, .checksFailed])
    }
}

@Suite struct StatusLineTests {
    @Test func eachStageHasItsLine() throws {
        let rows = try stageRows()
        let expected: [(WorktreeStage, String)] = [
            (.merged, "Merged 00:00"),
            (.closed, "Closed without a merge"),
            (.inMergeQueue, "Position 2 in the merge queue"),
            (.conflicts, "Conflicts with main"),
            (.changesRequested, "Changes requested \u{00B7} 3 comments"),
            (.checksFailed, "2 of 3 checks failed"),
            (.approvalNeeded, "1 workflow waits for approval"),
            (.draft, "Draft \u{00B7} 1 of 1 check done"),
            (.behindBase, "3 commits behind main"),
            (.checksRunning, "1 of 2 checks done"),
            (.waitingForReview, "Review required"),
            (.blocked, "GitHub blocks the merge"),
            (.readyToMerge, "1 of 1 check passed \u{00B7} Approved"),
            (.pushedNoPR, "Pushed, no PR"),
            (.notPushed, "1 changed"),
        ]
        for (stage, text) in expected {
            #expect(line(try row(stage, in: rows)).text == text, "\(stage)")
        }
    }

    @Test func readyToMergeWithOptionalChecksThatFailedSaysSo() throws {
        let unstable = try #require(try stageRows().last)
        #expect(unstable.stage == .readyToMerge)
        #expect(line(unstable).text == "2 of 2 required checks passed \u{00B7} 2 optional failed")
    }

    @Test func onlyTheFailingWordsAreFailing() throws {
        let rows = try stageRows()
        let failing = rows.filter { status in line(status).parts.contains { $0.failing } }
        #expect(failing.map(\.stage) == [.conflicts, .checksFailed])
        let failed = line(try row(.checksFailed, in: rows))
        #expect(failed.parts == [StatusLine.Part(text: "2 of 3 checks failed", failing: true)])
    }

    @Test func aPRThatIsBehindItsBaseSaysHowFarAfterTheStageWords() throws {
        var failed = try row(.checksFailed, in: try stageRows())
        failed.pr?.behindBase = 3
        let text = line(failed)
        #expect(text.text == "2 of 3 checks failed \u{00B7} 3 behind main")
        #expect(text.parts.map(\.failing) == [true, false])
        failed.pr?.behindBase = 0
        #expect(line(failed).text == "2 of 3 checks failed")
    }

    @Test func theBehindCountIsNotRepeatedByTheStagesThatSayIt() throws {
        let rows = try stageRows()
        var behind = try row(.behindBase, in: rows)
        behind.pr?.behindBase = 5
        #expect(line(behind).text == "5 commits behind main")
        var queued = try row(.inMergeQueue, in: rows)
        queued.pr?.behindBase = 5
        #expect(line(queued).text == "Position 2 in the merge queue")
        var merged = try row(.merged, in: rows)
        merged.pr?.behindBase = 5
        #expect(line(merged).text == "Merged 00:00")
    }

    @Test func theNameOfTheBaseBranchReplacesMain() throws {
        var conflicts = try row(.conflicts, in: try stageRows())
        conflicts.pr?.base = "trunk"
        #expect(line(conflicts).text == "Conflicts with trunk")
        var behind = try row(.behindBase, in: try stageRows())
        behind.pr?.base = "trunk"
        #expect(line(behind).text == "3 commits behind trunk")
    }

    @Test func oneOfSomethingIsSingular() throws {
        var behind = try row(.behindBase, in: try stageRows())
        behind.pr?.behindBase = 1
        #expect(line(behind).text == "1 commit behind main")
        var changes = try row(.changesRequested, in: try stageRows())
        changes.pr?.comments = 1
        #expect(line(changes).text == "Changes requested \u{00B7} 1 comment")
        var approval = try row(.approvalNeeded, in: try stageRows())
        approval.pr?.checks.waiting = 2
        #expect(line(approval).text == "2 workflows wait for approval")
    }

    @Test func changesRequestedWithNoCommentsSaysOnlyThat() throws {
        var changes = try row(.changesRequested, in: try stageRows())
        changes.pr?.comments = 0
        #expect(line(changes).text == "Changes requested")
    }

    @Test func aMergeOnAnotherDayShowsTheDay() throws {
        let later = ISO8601DateFormatter().date(from: "2026-01-05T12:00:00Z")!
        let merged = try row(.merged, in: try stageRows())
        #expect(line(merged, now: later).text == "Merged 1 Jan, 00:00")
    }

    @Test func aPRThatGitHubStillChecksSaysChecking() throws {
        var checking = try row(.checksRunning, in: try stageRows())
        checking.pr?.mergeable = "UNKNOWN"
        checking.pr?.checks = PRCheckCounts(state: "", total: 0, passed: 0, failed: 0, running: 0, waiting: 0)
        #expect(line(checking).text == "Checking\u{2026}")
        checking.pr?.checks.state = "EXPECTED"
        #expect(line(checking).text == "Waiting for checks")
    }

    @Test func readyToMergeNamesOnlyWhatIsKnown() throws {
        var ready = try row(.readyToMerge, in: try stageRows())
        ready.pr?.reviewDecision = ""
        #expect(line(ready).text == "1 of 1 check passed")
        ready.pr?.checks = PRCheckCounts(state: "", total: 0, passed: 0, failed: 0, running: 0, waiting: 0)
        #expect(line(ready).text == "Ready to merge")
        ready.pr?.reviewDecision = "APPROVED"
        #expect(line(ready).text == "Approved")
    }

    @Test func aWaitingReviewShowsTheApprovalsItHas() throws {
        var waiting = try row(.waitingForReview, in: try stageRows())
        waiting.pr?.approvals = 1
        #expect(line(waiting).text == "Review required \u{00B7} 1 approval")
    }

    // MARK: Local state

    private func local(changed: Int = 0, unpushed: Int = 0, stage: WorktreeStage? = nil) throws -> WorktreeStatus {
        var status = try row(.notPushed, in: try stageRows())
        status.changed = changed
        status.unpushed = unpushed
        status.stage = stage
        return status
    }

    @Test func withNoPRTheLineIsTheLocalState() throws {
        #expect(line(try local(changed: 2, stage: .notPushed)).text == "2 changed")
        #expect(line(try local(unpushed: 4, stage: .notPushed)).text == "4 commits not pushed")
        #expect(line(try local(unpushed: 1, stage: .notPushed)).text == "1 commit not pushed")
        #expect(line(try local(changed: 2, unpushed: 4, stage: .notPushed)).text == "2 changed \u{00B7} 4 commits not pushed")
    }

    @Test func aPushedBranchWithNoPRKeepsItsLocalWork() throws {
        #expect(line(try local(stage: .pushedNoPR)).text == "Pushed, no PR")
        #expect(line(try local(changed: 2, stage: .pushedNoPR)).text == "Pushed, no PR \u{00B7} 2 changed")
    }

    @Test func aCleanWorktreeWithNoStageSaysSo() throws {
        #expect(line(try local(stage: .noStage)).text == "No changes")
    }

    @Test func aCoreWithNoShipStateGivesTheLocalLine() throws {
        #expect(line(try local(changed: 3, stage: nil)).text == "3 changed")
    }

    @Test func aFolderThatIsGoneHasNoPRData() throws {
        var gone = try row(.checksFailed, in: try stageRows())
        gone.missing = true
        #expect(line(gone).text == "Folder is gone")
        #expect(line(gone).parts.allSatisfy { !$0.failing })
    }
}

@Suite struct ShipAgeTests {
    private func rows(checkedAt: [String?]) throws -> [WorktreeStatus] {
        let base = try stageRows()
        return checkedAt.enumerated().map { index, at in
            var status = base[index]
            status.prCheckedAt = at
            return status
        }
    }

    private func at(_ time: String) -> Date { ISO8601DateFormatter().date(from: time)! }

    @Test func freshDataShowsNoAge() throws {
        let list = try rows(checkedAt: ["2026-01-01T18:00:00Z"])
        #expect(ShipAge.label(for: list, now: at("2026-01-01T18:03:00Z"), timeZone: utc) == nil)
    }

    @Test func dataThatIsExactlyFiveMinutesOldIsStillFresh() throws {
        let list = try rows(checkedAt: ["2026-01-01T18:00:00Z"])
        #expect(ShipAge.staleAfter == 300)
        #expect(ShipAge.label(for: list, now: at("2026-01-01T18:05:00Z"), timeZone: utc) == nil)
    }

    @Test func dataMoreThanFiveMinutesOldShowsItsTime() throws {
        let list = try rows(checkedAt: ["2026-01-01T18:02:00Z"])
        #expect(ShipAge.label(for: list, now: at("2026-01-01T18:07:01Z"), timeZone: utc) == "Updated 18:02")
    }

    @Test func theOldestRowSetsTheAge() throws {
        let list = try rows(checkedAt: ["2026-01-01T18:14:00Z", "2026-01-01T18:02:00Z", "2026-01-01T18:10:00Z"])
        #expect(ShipAge.label(for: list, now: at("2026-01-01T18:30:00Z"), timeZone: utc) == "Updated 18:02")
    }

    @Test func rowsWithNoTimeAreLeftOut() throws {
        let list = try rows(checkedAt: [nil, "2026-01-01T18:02:00Z", nil])
        #expect(ShipAge.label(for: list, now: at("2026-01-01T18:30:00Z"), timeZone: utc) == "Updated 18:02")
        #expect(ShipAge.label(for: try rows(checkedAt: [nil, nil]), now: at("2026-01-01T18:30:00Z"), timeZone: utc) == nil)
        #expect(ShipAge.label(for: [], now: at("2026-01-01T18:30:00Z"), timeZone: utc) == nil)
    }

    @Test func aFolderThatIsGoneHasNoAge() throws {
        var list = try rows(checkedAt: ["2026-01-01T09:00:00Z", "2026-01-01T18:14:00Z"])
        list[0].missing = true
        #expect(ShipAge.label(for: list, now: at("2026-01-01T18:16:00Z"), timeZone: utc) == nil)
    }

    @Test func dataFromAnotherDayShowsTheDay() throws {
        let list = try rows(checkedAt: ["2026-01-01T18:02:00Z"])
        #expect(ShipAge.label(for: list, now: at("2026-01-03T09:00:00Z"), timeZone: utc) == "Updated 1 Jan, 18:02")
    }
}

@Suite struct ShipNoticeTests {
    private func rows(_ notes: [PRNote]) throws -> [WorktreeStatus] {
        let base = try stageRows()
        return notes.enumerated().map { index, note in
            var status = base[index]
            status.prNote = note
            return status
        }
    }

    @Test func eachNoteHasItsWords() {
        #expect(ShipNotice.ghMissing.message == "Install the GitHub CLI to see pull requests. Run:")
        #expect(ShipNotice.ghMissing.command == "brew install gh")
        #expect(ShipNotice.ghSignedOut.message == "Sign in to the GitHub CLI to see pull requests.")
        #expect(ShipNotice.ghSignedOut.command == nil)
        #expect(ShipNotice.noAccess.message == "The GitHub CLI cannot read this repo. Run:")
        #expect(ShipNotice.noAccess.command == "gh auth status")
    }

    @Test func aNoteThatNeedsAFixGivesANotice() throws {
        #expect(ShipNotice.current(for: try rows([.ghMissing]), dismissed: []) == [.ghMissing])
        #expect(ShipNotice.current(for: try rows([.noNote, .ghSignedOut]), dismissed: []) == [.ghSignedOut])
        #expect(ShipNotice.current(for: try rows([.noAccess]), dismissed: []) == [.noAccess])
    }

    @Test func theOtherNotesGiveNoNotice() throws {
        for note in [PRNote.noNote, .noGitHubRemote, .offline, .rateLimited] {
            #expect(ShipNotice.current(for: try rows([note]), dismissed: []).isEmpty, "\(note)")
        }
        #expect(ShipNotice.current(for: [], dismissed: []).isEmpty)
    }

    @Test func aDismissedNoticeStaysHidden() throws {
        let list = try rows([.ghMissing, .noAccess])
        #expect(ShipNotice.current(for: list, dismissed: [.ghMissing]) == [.noAccess])
        #expect(ShipNotice.current(for: list, dismissed: [.ghMissing, .noAccess]).isEmpty)
    }

    @Test func eachNoticeShowsOnceInAFixedOrder() throws {
        let list = try rows([.noAccess, .ghSignedOut, .ghMissing, .ghMissing])
        #expect(ShipNotice.current(for: list, dismissed: []) == [.ghMissing, .ghSignedOut, .noAccess])
    }
}

@Suite struct PaneTextTests {
    @Test func textWithNoLineBreakStaysAsItIs() {
        #expect(PaneText.withoutReturn("gh auth login") == "gh auth login")
        #expect(PaneText.withoutReturn("") == "")
    }

    @Test func aLineBreakAtTheEndIsRemoved() {
        #expect(PaneText.withoutReturn("gh auth login\n") == "gh auth login")
        #expect(PaneText.withoutReturn("gh auth login\r") == "gh auth login")
        #expect(PaneText.withoutReturn("gh auth login\r\n") == "gh auth login")
        #expect(PaneText.withoutReturn("gh auth login\n\n\n") == "gh auth login")
        #expect(PaneText.withoutReturn("\n") == "")
    }

    @Test func aLineBreakInsideStaysForAProgramThatTakesAPaste() {
        #expect(PaneText.withoutReturn("one\ntwo\n") == "one\ntwo")
    }
}
