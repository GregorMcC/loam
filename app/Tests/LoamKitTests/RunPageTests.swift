import Foundation
import Testing

@testable import LoamKit

/// Ticket 203: Today and the run page in the well, and the tab that watches a run.
@MainActor
@Suite(.waitLimit) struct RunPageTests {
    /// The run of the fixtures is in the plot plotaaaaae.
    func model(_ fixtures: [(String, Int32)]) throws -> (AppModel, FakeLoam) {
        let fake = try FakeLoam(fixtures)
        let model = AppModel(client: fake.client())
        model.apply([PlotSummary(id: "plotaaaaae", name: "Runs", what: "", createdAt: "2026-01-01T00:00:00Z")])
        return (model, fake)
    }

    @Test func todayOpensAndAMoveToASpaceClosesIt() throws {
        let (model, _) = try model([("run_list", 0)])
        model.showToday()
        #expect(model.page == .today)
        model.activate(plot: "plotaaaaae")
        #expect(model.page == nil)
        model.showToday()
        model.openTab(.shell)
        #expect(model.page == nil)
    }

    @Test func theRunPageReadsTheRunAndItsHistory() async throws {
        let (model, fake) = try model([("run_list", 0), ("run_status", 0)])
        await model.reloadRuns()
        #expect(model.runs.map(\.id) == ["runraaaaab"])
        #expect(model.today.recent.map(\.plotName) == ["Runs"])
        await model.openRun("runraaaaab")
        #expect(model.page == .run("runraaaaab"))
        #expect(model.runStatus?.events.map(\.detail) == ["starting", "running"])
        #expect(fake.args() == ["run list --json", "run status --json -- runraaaaab"])
    }

    /// Ticket 206: a tick that moved a run reads the runs again. A tick that moved none reads nothing.
    @Test func aTickThatShipsARunReadsTheRunsAgain() async throws {
        let (model, fake) = try model([("run_tick", 0), ("run_list", 0)])
        await model.tickRuns()
        #expect(fake.args() == ["run tick --json", "run list --json"])
        let tick = try JSONDecoder().decode(RunTickResult.self, from: Fixtures.data("run_tick"))
        #expect(tick.runs.first?.state == .shipping)
        #expect(tick.runs.first?.pr == RunPR(number: 25, url: "https://github.com/example/widgets/pull/25"))
        #expect(tick.runs.first?.state.station == .ship)
    }

    /// Ticket 207: a tick watches a run that ships, and a ready run with a PR, which a merge on GitHub lands.
    @Test func aTickWatchesRunsThatWaitOnGitHub() {
        var run = TodayContentTests.run("r1", plot: "p1", .shipping)
        #expect(run.waitsOnGitHub)
        run.state = .ready
        #expect(!run.waitsOnGitHub)
        run.pr = RunPR(number: 25, url: "https://github.com/example/widgets/pull/25")
        #expect(run.waitsOnGitHub)
        run.state = .landed
        #expect(!run.waitsOnGitHub)
    }

    @Test func watchOpensAShellTabThatAttachesToTheSession() async throws {
        let (model, _) = try model([("run_list", 0)])
        await model.reloadRuns()
        var run = try #require(model.runs.first)
        // No session yet: nothing to attach to.
        model.watchRun(run)
        #expect(model.workspace.tabs(of: "plotaaaaae").isEmpty)

        run.sessionID = "c57ef956-3136-4e86-bfde-da8facfe0523"
        model.showToday()
        model.watchRun(run)
        #expect(model.page == nil)
        #expect(model.workspace.activeSpace == .plot("plotaaaaae"))
        let tab = try #require(model.workspace.tabs(of: "plotaaaaae").first)
        let spec = try #require(model.workspace.spec(of: tab.focused))
        #expect(spec.kind == .shell)
        #expect(spec.folder == run.folder)
        #expect(spec.title == "Fix the login form")
        #expect(spec.command?.hasSuffix("'exec claude attach c57ef956'") == true)
    }
}
