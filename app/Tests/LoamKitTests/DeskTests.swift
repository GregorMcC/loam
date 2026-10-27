import Foundation
import Testing

@testable import LoamKit

/// Ticket 207: the desk takes the runs that wait for you one at a time: Land first, then Stopped.
@MainActor
@Suite(.waitLimit) struct DeskTests {
    static func run(_ id: String, _ state: RunState, updated: String) -> Run {
        TodayContentTests.run(id, plot: "plotaaaaae", state, updated: updated)
    }

    /// r1 and r3 are ready, r1 the longer. r2 stopped. r4 runs.
    func model(_ fixtures: [(String, Int32)]) throws -> (AppModel, FakeLoam) {
        let fake = try FakeLoam(fixtures)
        let model = AppModel(client: fake.client())
        model.apply([PlotSummary(id: "plotaaaaae", name: "Runs", what: "", createdAt: "2026-01-01T00:00:00Z")])
        model.runs = [
            Self.run("r4", .running, updated: "2026-10-27T18:00:00Z"),
            Self.run("r3", .ready, updated: "2026-10-27T17:00:00Z"),
            Self.run("r2", .stopped, updated: "2026-10-27T16:30:00Z"),
            Self.run("r1", .ready, updated: "2026-10-27T16:00:00Z"),
        ]
        return (model, fake)
    }

    @Test func theQueueIsLandThenStoppedTheLongestWaitFirst() throws {
        let (model, _) = try model([])
        #expect(model.deskQueue.map(\.id) == ["r1", "r3", "r2"])
    }

    @Test func theDeskOpensOnTheFirstItemAndReadsItsDiff() async throws {
        let (model, fake) = try model([("run_diff", 0), ("run_status", 0)])
        await model.openDesk()
        #expect(model.page == .desk)
        #expect(model.desk.runID == "r1")
        #expect(model.desk.diff?.files.map(\.path) == ["README.md"])
        #expect(model.desk.file == "README.md")
        #expect(fake.args() == ["run diff --json -- r1", "run status --json -- r1"])
        model.leaveDesk()
        #expect(model.page == .today)
    }

    @Test func nextAndPreviousStayInTheQueue() async throws {
        let (model, _) = try model(Array(repeating: ("run_diff", 0), count: 8))
        await model.openDesk()
        await model.moveDesk(by: -1)
        #expect(model.desk.runID == "r1")
        await model.moveDesk(by: 1)
        await model.moveDesk(by: 1)
        #expect(model.desk.runID == "r2")
        await model.moveDesk(by: 1)
        #expect(model.desk.runID == "r2")
    }

    @Test func notesGoBackAsOneBatch() async throws {
        let (model, fake) = try model([("run_diff", 0), ("run_status", 0), ("run_send_back", 0), ("run_list", 0)])
        await model.openDesk()
        model.addDeskNote(file: "README.md", line: 3, text: "Say what a plot is.")
        model.addDeskNote(file: nil, line: nil, text: "  Keep the README short. ")
        model.addDeskNote(file: nil, line: nil, text: "   ")
        #expect(model.desk.notes["r1"]?.count == 2)
        let first = try #require(model.desk.notes["r1"]?.first)
        model.removeDeskNote(first.id)
        model.addDeskNote(file: "README.md", line: 3, text: "Say what a plot is.")
        await model.sendBackDeskNotes()
        #expect(fake.args().dropFirst(2).first == "run send-back --note Keep the README short. "
            + "--note README.md:3: Say what a plot is. --json -- r1")
        #expect(model.desk.notes["r1"] == nil)
        #expect(model.desk.error == nil)
    }

    @Test func aMergeNamesTheHeadThatYouRead() async throws {
        let (model, fake) = try model([("run_diff", 0), ("run_status", 0), ("run_land", 0), ("run_list", 0)])
        await model.openDesk()
        model.desk.keepWorktree = true
        await model.landDeskRun()
        #expect(fake.args().dropFirst(2).first
            == "run land --head 1234512345123451234512345123451234512345 --keep-worktree --json -- r1")
        #expect(model.desk.error == nil)
    }

    /// The merge can remove the worktree of the run, so the sidebar reads the worktrees again. The toast says
    /// what the merge did, as at the Land sheet.
    @Test func aMergeReadsTheWorktreesAgainAndSaysWhatItDid() async throws {
        let (model, fake) = try model([("run_diff", 0), ("run_status", 0), ("run_land", 0), ("run_list", 0),
                                       ("run_diff", 0), ("run_status", 0), ("worktree_list", 0)])
        var toasts: [String] = []
        model.onToast = { text, _ in toasts.append(text) }
        await model.openDesk()
        await model.landDeskRun()
        #expect(fake.args().last?.contains("worktree list") == true)
        #expect(toasts == ["Merged #25. Removed the worktree tidy-the-readme."])
    }

    /// A tick can land a run that the desk shows, when its PR merged on GitHub. The desk then shows the next
    /// run, or nothing.
    @Test func aRunThatLeavesTheQueueLeavesTheDesk() async throws {
        let (model, _) = try model([("run_diff", 0), ("run_status", 0), ("run_list", 0)])
        await model.openDesk()
        #expect(model.desk.runID == "r1")
        await model.reloadRuns()
        #expect(model.desk.runID == nil && model.desk.diff == nil)
    }

    @Test func aMergeThatFailsKeepsTheItemAndSaysWhy() async throws {
        let (model, _) = try model([("run_diff", 0), ("run_status", 0), ("error_run_land_not_ready", 2)])
        await model.openDesk()
        await model.landDeskRun()
        #expect(model.page == .desk && model.desk.runID == "r1")
        #expect(model.desk.error?.contains("Ready to land") == true)
        #expect(!model.desk.busy)
    }
}
