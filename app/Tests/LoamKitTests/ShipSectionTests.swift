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

    /// Checks running with no check that runs or waits, and a summary that is not PENDING or EXPECTED:
    /// GitHub has not finished its merge check, so the line says "Checking…" whatever the counts are.
    @Test func checksRunningWithNoCheckThatRunsOrWaitsSaysChecking() throws {
        for state in ["", "SUCCESS", "FAILURE"] {
            var checking = try row(.checksRunning, in: try stageRows())
            checking.pr?.mergeable = "UNKNOWN"
            checking.pr?.checks.running = 0
            checking.pr?.checks.waiting = 0
            checking.pr?.checks.state = state
            #expect(line(checking).text == "Checking\u{2026}", "state \"\(state)\"")
        }
        var passed = try row(.checksRunning, in: try stageRows())
        passed.pr?.checks = PRCheckCounts(state: "SUCCESS", total: 3, passed: 3, failed: 0, running: 0, waiting: 0,
                                          required: 3, requiredPassed: 3)
        #expect(line(passed).text == "Checking\u{2026}")
    }

    /// A summary of PENDING or EXPECTED, a check that runs, or a check that waits keeps the count.
    @Test func checksRunningWithAnActiveCheckKeepsItsCount() throws {
        for state in ["PENDING", "EXPECTED"] {
            var running = try row(.checksRunning, in: try stageRows())
            running.pr?.checks.running = 0
            running.pr?.checks.waiting = 0
            running.pr?.checks.state = state
            #expect(line(running).text == "2 of 2 checks done", "state \(state)")
        }
        var runs = try row(.checksRunning, in: try stageRows())
        runs.pr?.checks.running = 1
        runs.pr?.checks.state = "SUCCESS"
        #expect(line(runs).text == "1 of 2 checks done")
        var waits = try row(.checksRunning, in: try stageRows())
        waits.pr?.checks.running = 0
        waits.pr?.checks.waiting = 1
        waits.pr?.checks.state = "SUCCESS"
        #expect(line(waits).text == "1 of 2 checks done")
    }

    @Test func checksRunningCountsTheChecksThatAreDone() throws {
        var running = try row(.checksRunning, in: try stageRows())
        running.pr?.checks.total = 14
        running.pr?.checks.running = 4
        running.pr?.checks.waiting = 1
        #expect(line(running).text == "9 of 14 checks done")
    }

    @Test func checksFailedWithNoChecksDoesNotCountThem() throws {
        var failed = try row(.checksFailed, in: try stageRows())
        failed.pr?.checks.total = 0
        failed.pr?.checks.failed = 0
        #expect(line(failed).parts == [StatusLine.Part(text: "Checks failed", failing: true)])
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

/// Without `gh` the core gives the local stage and a null PR (docs/contract.md, "Ship state of worktrees"),
/// so the app needs no rule for the note: a row shows what it is given.
@Suite struct RowsWithoutGitHubTests {
    /// A row as the core sends it when `gh` is missing or signed out: `pr` is null and the stage is local.
    private func decoded(note: String, stage: String, changed: Int = 0, unpushed: Int = 0) throws -> WorktreeStatus {
        let json = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("worktree_list_stages")) as? [[String: Any]])
        var entry = try #require(json.first { $0["stage"] as? String == "not_pushed" })
        entry["pr"] = NSNull()
        entry["pr_note"] = note
        entry["stage"] = stage
        entry["changed"] = changed
        entry["unpushed"] = unpushed
        return try JSONDecoder().decode(WorktreeStatus.self, from: JSONSerialization.data(withJSONObject: entry))
    }

    private let notes = ["gh_missing", "gh_signed_out"]

    @Test func aRowWithNoPRShowsLocalState() throws {
        for note in notes {
            #expect(line(try decoded(note: note, stage: "not_pushed", changed: 2)).text == "2 changed", "\(note)")
            #expect(line(try decoded(note: note, stage: "not_pushed", unpushed: 4)).text == "4 commits not pushed", "\(note)")
            #expect(line(try decoded(note: note, stage: "pushed_no_pr")).text == "Pushed, no PR", "\(note)")
            #expect(line(try decoded(note: note, stage: "")).text == "No changes", "\(note)")
        }
    }

    @Test func aRowWithNoPRHasNoPullRequestToOpen() throws {
        for note in notes {
            let status = try decoded(note: note, stage: "not_pushed", changed: 2)
            #expect(status.pr == nil && status.pullRequestPage == nil, "\(note)")
            // The callout still shows, since the note is the row's.
            #expect(status.prNote.flatMap(ShipNotice.init) != nil, "\(note)")
        }
    }

    @Test func aRowWithAPRCanOpenItsPage() throws {
        let status = try row(.checksFailed, in: try stageRows())
        #expect(status.pullRequestPage?.absoluteString == status.pr?.url)
        #expect(status.pullRequestPage?.scheme == "https")
    }

    @Test func onlyAnHTTPSAddressOpens() throws {
        var status = try row(.checksFailed, in: try stageRows())
        for address in ["http://github.com/example/widgets/pull/16", "file:///etc/passwd", "javascript:alert(1)", ""] {
            status.pr?.url = address
            #expect(status.pullRequestPage == nil, "\(address)")
        }
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

    @Test func aTimeWithFractionalSecondsReads() throws {
        let list = try rows(checkedAt: ["2026-01-01T18:02:00.250Z"])
        #expect(ShipAge.label(for: list, now: at("2026-01-01T18:30:00Z"), timeZone: utc) == "Updated 18:02")
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
    @Test func textWithNoLineBreakStaysAsItIs() throws {
        #expect(try PaneText.withoutReturn("gh auth login") == "gh auth login")
        #expect(try PaneText.withoutReturn("") == "")
    }

    @Test func aLineBreakAtTheEndIsRemoved() throws {
        #expect(try PaneText.withoutReturn("gh auth login\n") == "gh auth login")
        #expect(try PaneText.withoutReturn("gh auth login\r") == "gh auth login")
        #expect(try PaneText.withoutReturn("gh auth login\r\n") == "gh auth login")
        #expect(try PaneText.withoutReturn("gh auth login\n\n\n") == "gh auth login")
        #expect(try PaneText.withoutReturn("\n") == "")
    }

    /// A program that takes no bracketed paste reads a line break as Return, so text with a line break
    /// inside it is not typed. Ticket 110 widens this for a prompt with more than one line.
    @Test func aLineBreakInsideIsRefused() {
        for text in ["one\ntwo", "one\ntwo\n", "one\r\ntwo", "one\rtwo", "\none", "one\n\ntwo\n\n", "one\u{2028}two"] {
            #expect(throws: PaneTextError.lineBreakInside, "\(text.debugDescription)") { try PaneText.withoutReturn(text) }
        }
    }

    @Test func theRefusalSaysWhy() {
        #expect(PaneTextError.lineBreakInside.description
            == "Loam does not type text that has a line break inside it. A program with no bracketed paste reads it as Return.")
    }
}
