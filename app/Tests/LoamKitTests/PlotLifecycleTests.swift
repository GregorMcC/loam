import Foundation
import Testing

@testable import LoamKit

/// Archive, unarchive, and delete in the app (ticket 48). The fake `loam` cannot give the list that
/// the core would give after an archive, so the reload after each call fails here (`error_generic`)
/// and keeps what the call itself set. The driver test runs the real core.
@MainActor
@Suite struct PlotLifecycleTests {
    func plot(_ id: String, _ name: String) -> PlotSummary {
        PlotSummary(id: id, name: name, what: "", createdAt: "2026-01-01T00:00:00Z")
    }

    func event(_ name: String, _ id: String) -> PaneEvent {
        PaneEvent(event: name, sessionID: id, cwd: "/repo/a", at: "2026-10-03T09:00:00Z", source: nil, notificationType: nil)
    }

    /// Two plots. "plotaaaaab" is active with a started session (last hook `hook`) and a shell split.
    func model(_ fake: FakeLoam, hook: String = "Stop") -> (model: AppModel, session: PaneID, shell: PaneID) {
        let model = AppModel(client: fake.client())
        model.shell = "/bin/zsh"
        model.apply([plot("plotaaaaab", "Loam"), plot("plotaaaaac", "Loam Docs")])
        model.openTab(.session)
        let session = model.workspace.selectedTab(of: "plotaaaaab")!.focused
        let id = model.workspace.spec(of: session)!.sessionID!
        model.apply(event("SessionStart", id), to: session)
        model.apply(event(hook, id), to: session)
        model.split(.sideBySide, .shell, folder: "/repo/a")
        let shell = model.workspace.selectedTab(of: "plotaaaaab")!.focused
        return (model, session, shell)
    }

    @Test func clientCallsArchiveUnarchiveAndDelete() async throws {
        let fake = try FakeLoam([("archive", 0), ("unarchive", 0), ("delete", 0)])
        let client = fake.client()
        #expect(try await client.archive(plot: "p").archived)
        _ = try await client.unarchive(plot: "p")
        let result = try await client.delete(plot: "p")
        #expect(result.claudeFiles.count == 1)
        #expect(fake.args() == ["archive p --json --actor app", "unarchive p --json --actor app", "delete p --json --actor app"])
    }

    @Test func archiveAsksOnlyWhileASessionIsWorking() throws {
        let idle = try model(FakeLoam([("archive", 0)]))
        #expect(idle.model.archivePrompt(for: "plotaaaaab") == nil)
        let busy = try model(FakeLoam([("archive", 0)]), hook: "UserPromptSubmit")
        let prompt = busy.model.archivePrompt(for: "plotaaaaab")
        #expect(prompt?.confirm == "Archive")
        #expect(prompt?.message.contains("1 session") == true)
        #expect(busy.model.archivePrompt(for: "plotaaaaac") == nil)
    }

    @Test func archiveEndsTheSessionsAndKeepsTheLayout() async throws {
        let fake = try FakeLoam([("archive", 0), ("error_generic", 1)])
        let (model, session, shell) = try model(fake, hook: "UserPromptSubmit")
        let tabs = model.workspace.tabs(of: "plotaaaaab")
        let sessionID = model.workspace.session(of: session)!.sessionID!
        #expect(await model.archivePlot("plotaaaaab"))
        #expect(fake.args().first == "archive plotaaaaab --json --actor app")
        #expect(model.plots.map(\.id) == ["plotaaaaac"])
        #expect(model.archivedPlots.map(\.id) == ["plotaaaaab"])
        #expect(model.archivedPlots.first?.archived == true)
        // The layout stays, and no pane has a process.
        #expect(model.workspace.tabs(of: "plotaaaaab") == tabs)
        #expect(model.workspace.isWaiting("plotaaaaab"))
        #expect(model.workspace.livePaneIDs.isEmpty)
        // The session comes back by resume. The shell comes back in the same folder. No stale mark stays.
        let command = model.workspace.spec(of: session)?.command ?? ""
        #expect(command.contains("resume") && command.contains(sessionID))
        #expect(model.workspace.state(of: session) == .running)
        #expect(model.workspace.spec(of: shell)?.kind == .shell)
        #expect(model.workspace.spec(of: shell)?.folder == "/repo/a")
    }

    @Test func archiveMovesTheActivePlotToTheNextOne() async throws {
        let fake = try FakeLoam([("archive", 0), ("error_generic", 1)])
        let (model, _, _) = try model(fake)
        #expect(model.workspace.activePlotID == "plotaaaaab")
        #expect(await model.archivePlot("plotaaaaab"))
        #expect(model.workspace.activePlotID == "plotaaaaac")
    }

    @Test func archiveOfAnInactivePlotKeepsTheActiveOne() async throws {
        let fake = try FakeLoam([("archive", 0), ("error_generic", 1)])
        let (model, _, _) = try model(fake)
        #expect(await model.archivePlot("plotaaaaac"))
        #expect(model.workspace.activePlotID == "plotaaaaab")
        #expect(model.workspace.livePaneIDs(of: "plotaaaaab").count == 2)
    }

    @Test func aFailedArchiveEndsNoSession() async throws {
        let fake = try FakeLoam([("error_generic", 1)])
        let (model, session, _) = try model(fake, hook: "UserPromptSubmit")
        #expect(await model.archivePlot("plotaaaaab") == false)
        #expect(model.lastError != nil)
        #expect(!model.workspace.isWaiting("plotaaaaab"))
        #expect(model.workspace.state(of: session) == .working)
        #expect(model.workspace.activePlotID == "plotaaaaab")
        #expect(model.plots.count == 2)
    }

    @Test func anUnarchivedPlotStartsItsPanesWhenYouShowIt() async throws {
        let fake = try FakeLoam([("archive", 0), ("error_generic", 1), ("unarchive", 0), ("error_generic", 1)])
        let (model, session, _) = try model(fake)
        _ = await model.archivePlot("plotaaaaab")
        #expect(await model.unarchivePlot("plotaaaaab"))
        #expect(fake.args().contains("unarchive plotaaaaab --json --actor app"))
        model.apply([plot("plotaaaaab", "Loam"), plot("plotaaaaac", "Loam Docs")])  // What the core lists now.
        #expect(model.workspace.livePaneIDs(of: "plotaaaaab").isEmpty)
        model.activate(plot: "plotaaaaab")
        #expect(model.workspace.livePaneIDs(of: "plotaaaaab").contains(session))
    }

    /// Ticket 61: a feed reload that straddles an archive or unarchive can miss a plot in both
    /// lists. The second read finds it, so its panes stay.
    @Test func aPlotThatOneReadMissesKeepsItsPanes() async throws {
        let fake = try FakeLoam([("list_empty", 0), ("list_empty", 0), ("list", 0), ("list_archived", 0)])
        let (model, session, shell) = try model(fake)
        await model.reloadPlots()
        #expect(fake.args().count == 4)
        #expect(Set(model.workspace.paneIDs(of: "plotaaaaab")) == [session, shell])
    }

    /// A feed reload and an unarchive reload at the same time. The reads run one after the other,
    /// the calls that come during a read share the next read, and the newest list stays.
    @Test func plotReadsRunOneAtATimeAndTheNewestListStays() async throws {
        let fake = try FakeLoam([("list", 0), ("list_archived", 0), ("list_empty", 0), ("list_empty", 0)])
        let model = AppModel(client: fake.client())
        let first = Task { await model.reloadPlots() }
        // Wait until the first read has started, so the next calls come during it.
        while fake.args().isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        let second = Task { await model.reloadPlots() }
        let third = Task { await model.reloadPlots() }
        await second.value
        // The second call returns only after a read that started after it.
        #expect(model.plots.isEmpty && model.archivedPlots.isEmpty)
        await third.value
        await first.value
        #expect(fake.args() == ["list --json", "list --archived --json", "list --json", "list --archived --json"])
    }

    @Test func aPlotThatTwoReadsMissLosesItsPanes() async throws {
        let fake = try FakeLoam([("list_empty", 0)])
        let (model, _, _) = try model(fake)
        await model.reloadPlots()
        #expect(fake.args().count == 4)
        #expect(model.workspace.paneIDs(of: "plotaaaaab").isEmpty)
    }

    @Test func deleteReturnsTheResultAndTheNextPlotListDropsThePanes() async throws {
        let fake = try FakeLoam([("delete", 0), ("error_generic", 1)])
        let (model, _, _) = try model(fake)
        model.activate(plot: "plotaaaaac")
        model.openTab(.shell)
        model.apply([plot("plotaaaaab", "Loam")], archived: [plot("plotaaaaac", "Loam Docs")])
        #expect(model.workspace.paneCount(of: "plotaaaaac") == 1)  // An archived plot keeps its panes.
        let result = await model.deletePlot("plotaaaaac")
        #expect(result?.claudeFiles.count == 1)
        #expect(fake.args().first == "delete plotaaaaac --json --actor app")
        model.apply([plot("plotaaaaab", "Loam")])  // The core no longer lists it.
        #expect(model.workspace.tabs(of: "plotaaaaac").isEmpty)
        #expect(model.savedLayout.panes.allSatisfy { $0.plotID != "plotaaaaac" })
    }

    @Test func deleteRefusesAPlotThatIsNotArchived() async throws {
        let fake = try FakeLoam([("delete", 0)])
        let (model, _, _) = try model(fake)
        #expect(await model.deletePlot("plotaaaaab") == nil)
        #expect(model.lastError != nil)
        #expect(fake.args().isEmpty)
    }

    @Test func aCoreRefusalOfDeleteSetsTheError() async throws {
        let fake = try FakeLoam([("error_delete_not_archived", 1)])
        let (model, _, _) = try model(fake)
        model.apply([plot("plotaaaaab", "Loam")], archived: [plot("plotaaaaac", "Loam Docs")])
        #expect(await model.deletePlot("plotaaaaac") == nil)
        #expect(model.lastError?.contains("not archived") == true)
    }
}
