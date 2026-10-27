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

    // MARK: Shape

    /// A run in Shaping that Claude drafted, with one assumption.
    static func shaping(_ id: String = "s1") -> Run {
        var run = Self.run(id, .shaping, updated: "2026-10-27T18:30:00Z")
        run.goal = "The run page shows the plan of the run."
        run.doneWhen = [RunCheck(name: "Go tests", command: "go test ./...")]
        run.shape = RunShape(assumptions: [RunAssumption(text: "The plan shows as a numbered list.")],
                             plan: ["Read the plan.", "Show it."], size: "About 60 lines.",
                             draftedAt: "2026-10-27T18:30:00Z", repo: "repoaaaaag", base: "", link: "", model: "")
        return run
    }

    /// Nothing starts until you approve a draft, so Shaping comes first. A draft has no diff to read.
    @Test func shapingComesFirstAndShowsItsDraftWithNoDiff() async throws {
        let (model, fake) = try model([("run_status", 0)])
        model.runs.append(Self.shaping())
        #expect(model.deskQueue.map(\.id) == ["s1", "r1", "r3", "r2"])
        await model.openDesk()
        #expect(model.desk.runID == "s1" && model.desk.diff == nil && model.desk.error == nil)
        #expect(fake.args() == ["run status --json -- s1"])
    }

    /// The run of a Shaping row on Today opens at the desk, where you can approve it.
    @Test func aShapingRunOpensAtTheDesk() async throws {
        let (model, _) = try model([("run_status", 0)])
        model.runs.append(Self.shaping())
        await model.openRun("s1")
        #expect(model.page == .desk && model.desk.runID == "s1")
    }

    /// Only what you changed goes to the core: a goal that you set back to the draft is not sent.
    @Test func anApprovalSendsYourEditsOfTheDraft() async throws {
        let (model, fake) = try model([("run_status", 0), ("run_approve", 0), ("run_list", 0)])
        model.runs.append(Self.shaping())
        await model.openDesk()
        model.editDeskGoal("The run page shows the plan.")
        model.answerDeskAssumption(0, "  Bullets, not numbers. ")
        model.editDeskChecks([RunCheck(name: "All tests", command: "go test ./...")])
        await model.approveDeskRun()
        #expect(fake.args().dropFirst().first == "run approve --goal The run page shows the plan. "
            + "--check All tests=go test ./... --answer 1=Bullets, not numbers. --json -- s1")
        #expect(model.desk.error == nil && model.desk.shapeEdits["s1"] == nil)

        let (again, fake2) = try self.model([("run_status", 0), ("run_approve", 0), ("run_list", 0)])
        again.runs.append(Self.shaping())
        await again.openDesk()
        again.editDeskGoal("The run page shows the plan.")
        again.editDeskGoal("The run page shows the plan of the run.")
        again.answerDeskAssumption(0, "Bullets.")
        again.answerDeskAssumption(0, "")
        await again.approveDeskRun()
        #expect(fake2.args().dropFirst().first == "run approve --json -- s1")
    }

    /// When the core refuses a new setup command, the next approval approves it, as at Intake.
    @Test func anApprovalThatTheSetupStopsOffersToApproveIt() async throws {
        let (model, fake) = try model([("run_status", 0), ("run_approve", 0), ("run_list", 0)])
        model.runs.append(Self.shaping())
        await model.openDesk()
        model.desk.error = "the setup command of web is new or changed: make. add --approve-setup to approve it"
        #expect(model.desk.needsSetupApproval)
        await model.approveDeskRun()
        #expect(fake.args().dropFirst().first == "run approve --approve-setup --json -- s1")
    }

    @Test func aChangeGoesToClaudeForANewDraft() async throws {
        let (model, fake) = try model([("run_status", 0), ("run_shape", 0), ("run_list", 0), ("run_status", 0)])
        model.runs.append(Self.shaping())
        await model.openDesk()
        await model.redraftDeskRun(change: "  Add a check for the app. ")
        #expect(fake.args().dropFirst().first == "run redraft --change Add a check for the app. --json -- s1")
        #expect(model.desk.drafting.isEmpty && model.desk.error == nil)
    }

    /// Not now cancels the run, and the desk shows the next item.
    @Test func notNowCancelsTheDraft() async throws {
        let (model, fake) = try model([("run_status", 0), ("run_stop", 0), ("run_list", 0)])
        model.runs.append(Self.shaping())
        await model.openDesk()
        await model.notNowDeskRun()
        #expect(fake.args().dropFirst().first == "run stop --json -- s1")
    }

    /// Shape with Claude at Intake drafts the run, then shows the draft at the desk.
    @Test func shapeWithClaudeOpensTheDraftAtTheDesk() async throws {
        let (model, fake) = try model([("run_shape", 0), ("run_list", 0), ("run_status", 0)])
        var draft = RunDraft(item: IntakeItem(source: "map", key: "map 12", title: "Show the plan on the run page",
                                              status: "", priority: "", labels: [],
                                              url: "/tmp/loam-contract/build/issues/12-run-page-plan.md",
                                              updatedAt: "", runID: ""))
        draft.maxTries = 4
        #expect(await model.shapeRun(plot: "plotaaaaae", draft: draft))
        #expect(fake.args().first == "run shape --title Show the plan on the run page --max-tries 4 "
            + "--ticket /tmp/loam-contract/build/issues/12-run-page-plan.md --json -- plotaaaaae")
        #expect(model.page == .desk && model.desk.runID == "runraaaaad")
    }
}
