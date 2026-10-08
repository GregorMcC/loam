import Foundation
import Testing

@testable import LoamKit

@MainActor
@Suite struct AppModelTests {
    func plot(_ id: String, _ name: String) -> PlotSummary {
        PlotSummary(id: id, name: name, what: "", createdAt: "2026-01-01T00:00:00Z")
    }

    /// Ticket 96: the close button of a tab closes it by ID, selected or not.
    @Test func closesATabByIDInTheActivePlot() throws {
        let model = AppModel(client: LoamClient())
        model.apply([plot("p", "P")])
        model.activate(plot: "p")
        model.openTab(.shell)
        model.openTab(.shell)
        let tabs = model.workspace.tabs(of: "p")
        #expect(!model.closeTab(UUID()))
        #expect(model.closeTab(tabs[0].id))
        #expect(model.workspace.tabs(of: "p").map(\.id) == [tabs[1].id])
        #expect(model.workspace.selectedTab(of: "p")?.id == tabs[1].id)
    }

    @Test func reloadReadsTheListAndActivatesTheFirstPlot() async throws {
        let fake = try FakeLoam([("list", 0), ("list_archived", 0)])
        let model = AppModel(client: fake.client())
        await model.reloadPlots()
        #expect(model.plots.map(\.id) == ["plotaaaaab", "plotaaaaac"])
        #expect(model.workspace.activePlotID == "plotaaaaab")
        #expect(fake.args() == ["list --json", "list --archived --json"])
    }

    @Test func reloadLoadsThePanelOnlyWhileItShows() async throws {
        let fake = try FakeLoam([("list", 0), ("list_archived", 0), ("list", 0), ("list_archived", 0), ("show_links", 0)])
        let model = AppModel(client: fake.client())
        await model.reloadPlots()
        #expect(model.panel.plot == nil)
        model.panel.visible = true
        await model.reloadPlots()
        #expect(model.panel.plot?.id == "plotaaaaab")
    }

    @Test func aFailedReloadKeepsThePlotsAndSetsTheError() async throws {
        let fake = try FakeLoam([("list", 0), ("list_archived", 0), ("error_generic", 1)])
        let model = AppModel(client: fake.client())
        await model.reloadPlots()
        await model.reloadPlots()
        #expect(model.plots.count == 2)
        #expect(model.lastError != nil)
    }

    @Test func newPlotCallsLoamNewThenActivatesIt() async throws {
        let fake = try FakeLoam([("new_app", 0), ("list", 0)])
        let model = AppModel(client: fake.client())
        model.apply([plot("plotaaaaab", "Loam")])
        await model.newPlot(named: "  Loam  ")
        #expect(fake.args().first == "new Loam --json --actor app")
        #expect(model.workspace.activePlotID == "plotaaaaac")
    }

    @Test func newPlotWithABlankNameCallsNothing() async throws {
        let fake = try FakeLoam([("new_app", 0)])
        let model = AppModel(client: fake.client())
        await model.newPlot(named: "   ")
        #expect(fake.args().isEmpty)
    }

    @Test func movePlotCallsLoamMoveWithTheDropPosition() async throws {
        let fake = try FakeLoam([("move", 0), ("list", 0)])
        let model = AppModel(client: fake.client())
        model.apply([plot("plotaaaaab", "Loam"), plot("plotaaaaac", "Loam Docs")])
        await model.movePlot("plotaaaaac", onto: "plotaaaaab")
        #expect(fake.args().first == "move plotaaaaac 1 --json --actor app")
    }

    @Test func dropOnItselfCallsNothing() async throws {
        let fake = try FakeLoam([("move", 0)])
        let model = AppModel(client: fake.client())
        model.apply([plot("a", "A")])
        await model.movePlot("a", onto: "a")
        #expect(fake.args().isEmpty)
    }

    @Test func deletedPlotsLoseTheirTabsAndTheActivePlotMoves() {
        let model = AppModel(client: LoamClient())
        model.apply([plot("a", "A"), plot("b", "B")])
        model.activate(plot: "a")
        model.openTab()
        model.apply([plot("b", "B")])
        #expect(model.workspace.allPaneIDs.isEmpty)
        #expect(model.workspace.activePlotID == "b")
    }

    /// Ticket 93: a plot session runs in the plot folder of any plot, and a restart keeps it there.
    @Test func aPlotSessionStartsInThePlotFolder() throws {
        let model = AppModel(client: LoamClient())
        model.apply([plot("a", "A"), plot("b", "B")])
        model.activate(plot: "a")
        model.openPlotSession("b")
        #expect(model.workspace.activePlotID == "b")
        let pane = try #require(model.workspace.selectedTab(of: "b")?.focused)
        let spec = try #require(model.workspace.spec(of: pane))
        #expect(spec.kind == .session && spec.inPlotFolder)
        #expect(spec.command?.contains("--plot-folder") == true)
        #expect(spec.repo == nil && spec.worktree == nil)
        #expect(!model.newSessionSpec(in: "b").inPlotFolder)

        // A save and a restore keep it a plot session, and so does a resume.
        let saved = SavedLayout(workspace: model.workspace)
        let savedPane = try #require(saved.panes.first { $0.id == pane })
        let decoded = try JSONDecoder().decode(SavedLayout.Pane.self, from: JSONEncoder().encode(savedPane))
        #expect(decoded.plotFolder == true)
        #expect(model.restoreSpec(decoded)?.inPlotFolder == true)
        #expect(model.resumeSpec(in: "b", sessionID: "s", plotFolder: true).inPlotFolder)
    }

    @Test func anEmptyListClearsTheActivePlot() {
        let model = AppModel(client: LoamClient())
        model.apply([plot("a", "A")])
        model.apply([])
        #expect(model.workspace.activePlotID == nil)
        model.openTab()
        #expect(model.workspace.allPaneIDs.isEmpty)
    }

    @Test func tabAndSplitActionsApplyToTheActivePlot() {
        let model = AppModel(client: LoamClient())
        model.apply([plot("a", "A"), plot("b", "B")])
        model.activate(number: 2)
        model.openTab()
        model.split(.sideBySide)
        model.openTab()
        #expect(model.workspace.tabs(of: "b").count == 2)
        #expect(model.workspace.paneCount(of: "b") == 3)
        #expect(model.workspace.paneCount(of: "a") == 0)
        model.selectTab(number: 1)
        #expect(model.workspace.selectedTabIndex(of: "b") == 0)
        #expect(model.closeFocusedPane())
        #expect(model.workspace.paneCount(of: "b") == 2)
    }

    @Test func tabActionsWithNoActivePlotDoNothing() {
        let model = AppModel(client: LoamClient())
        model.openTab()
        model.split(.stacked)
        #expect(model.workspace.allPaneIDs.isEmpty)
        #expect(!model.closeFocusedPane())
    }

    @Test func switchingPlotsKeepsTheOtherPlotsPanes() {
        let model = AppModel(client: LoamClient())
        model.apply([plot("a", "A"), plot("b", "B")])
        model.openTab()
        model.activate(number: 2)
        model.openTab()
        model.activate(number: 1)
        #expect(model.workspace.paneCount(of: "a") == 1)
        #expect(model.workspace.paneCount(of: "b") == 1)
        #expect(model.sidebar.activePanes.count == 1)
        #expect(model.sidebar.withPanes.map(\.id) == ["a", "b"])
    }

    @Test func workspaceChangesCallTheObserver() {
        let model = AppModel(client: LoamClient())
        var calls = 0
        model.onWorkspaceChange = { calls += 1 }
        model.apply([plot("a", "A")])
        model.openTab()
        model.sidebarCollapsed = true
        #expect(calls >= 3)
    }

    @Test func aCLIArchiveKeepsThePlotsPanes() {
        let model = AppModel(client: LoamClient())
        model.apply([plot("a", "A"), plot("b", "B")])
        model.activate(plot: "a")
        model.openTab()
        model.apply([plot("b", "B")], archived: [plot("a", "A")])
        #expect(model.workspace.paneCount(of: "a") == 1)
        #expect(model.plots.map(\.id) == ["b"])
        #expect(model.archivedPlots.map(\.id) == ["a"])
        #expect(model.workspace.activePlotID == "b")
    }

    @Test func reloadReadsTheArchivedListToKeepArchivedPanes() async throws {
        let fake = try FakeLoam([("list", 0), ("list_archived", 0)])
        let model = AppModel(client: fake.client())
        model.apply([plot("plotaaaaac", "C")])
        model.openTab()
        await model.reloadPlots()
        #expect(fake.args() == ["list --json", "list --archived --json"])
        #expect(model.workspace.paneCount(of: "plotaaaaac") == 1)
    }

    @Test func aFailedArchivedReadKeepsEverything() async throws {
        let fake = try FakeLoam([("list", 0), ("error_generic", 1)])
        let model = AppModel(client: fake.client())
        model.apply([plot("x", "X")])
        model.openTab()
        await model.reloadPlots()
        #expect(model.workspace.paneCount(of: "x") == 1)
        #expect(model.lastError != nil)
    }

    @Test func everyFeedUpdateReloadsThePlotList() async throws {
        let fake = try FakeLoam([("list", 0), ("list_archived", 0)])
        let model = AppModel(client: fake.client())
        let (triggers, cont) = AsyncStream<Void>.makeStream()
        let feed = ChangeFeed(fetch: { _ in [] }, triggers: triggers, debounce: .milliseconds(1), after: 0)
        model.startFeed(feed: feed)
        cont.yield()  // A move or delete writes no new change.
        for _ in 0..<1000 {  // Up to 10 s: the suite runs in parallel and a launch can be slow.
            if !model.plots.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.stopFeed()
        cont.finish()
        #expect(model.plots.map(\.id) == ["plotaaaaab", "plotaaaaac"])
    }

    @Test func aRenameCallsTheObserverSoTheTitleUpdates() {
        let model = AppModel(client: LoamClient())
        model.apply([plot("a", "A")])
        var calls = 0
        model.onWorkspaceChange = { calls += 1 }
        model.apply([plot("a", "Renamed")])
        #expect(calls == 1)
    }

    /// Ticket 71: the main checkout row of a plot names the main repo's branch. The fixture's repo
    /// folder is not a checkout, so the label is the folder name. A plot with no main repo has none.
    @Test func theMainCheckoutsComeFromTheExport() async throws {
        let fake = try FakeLoam([("export", 0)])
        let model = AppModel(client: fake.client())
        await model.reloadMainCheckouts()
        #expect(model.mainCheckouts == ["plotaaaaab": "docs"])
        #expect(fake.args() == ["export --json"])
        model.apply([plot("plotaaaaab", "Loam"), plot("plotaaaaac", "Docs")])
        #expect(model.sidebar.tree(of: "plotaaaaab").checkouts.map(\.label) == ["docs"])
        #expect(model.sidebar.tree(of: "plotaaaaac").checkouts.isEmpty)
    }

    @Test func aFailedExportKeepsTheMainCheckouts() async throws {
        let fake = try FakeLoam([("export", 0), ("error_generic", 1)])
        let model = AppModel(client: fake.client())
        await model.reloadMainCheckouts()
        await model.reloadMainCheckouts()
        #expect(model.mainCheckouts == ["plotaaaaab": "docs"])
    }

    /// Ticket 71: a title change calls the observer once per run loop pass, and the same title again
    /// calls nothing. The workspace observer does not run, so the focus stays where it is.
    @Test func titleChangesCallTheTitleObserverOncePerPass() async throws {
        let model = AppModel(client: LoamClient())
        model.apply([plot("a", "A")])
        model.openTab()
        let pane = try #require(model.workspace.focusedPane)
        var titleCalls = 0
        var workspaceCalls = 0
        model.onTitleChange = { titleCalls += 1 }
        model.onWorkspaceChange = { workspaceCalls += 1 }
        for n in 0..<50 { model.setTerminalTitle("title \(n)", of: pane) }
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(titleCalls == 1)
        #expect(workspaceCalls == 0)
        #expect(model.sidebar.activePanes.first?.title == "title 49")
        model.setTerminalTitle("title 49", of: pane)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(titleCalls == 1)
    }
}
