import Foundation
import Testing

@testable import LoamKit

/// Ticket 99: Home, the space above the plots for tabs that belong to no plot.
@MainActor
@Suite struct HomeTests {
    func session(_ space: Space, _ id: String) -> PaneSpec {
        PaneSpec(kind: .session, space: space, command: "loam start", title: "claude", sessionID: id)
    }

    func shell(_ space: Space, _ folder: String = "~") -> PaneSpec {
        PaneSpec(kind: .shell, space: space, folder: folder, title: "shell")
    }

    func event(_ name: String, _ id: String) -> PaneEvent {
        PaneEvent(event: name, sessionID: id, cwd: "/Users/me", at: "2026-10-21T09:00:00Z", source: nil, notificationType: nil)
    }

    func plot(_ id: String, _ name: String? = nil) -> PlotSummary {
        PlotSummary(id: id, name: name ?? id, what: "", createdAt: "2026-01-01T00:00:00Z")
    }

    func tempFile() -> AppStateFile {
        AppStateFile(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("loam-home-\(UUID().uuidString)/state.json"))
    }

    /// Home: a session tab, then a shell tab (selected). Plot A: one shell tab. Home is active.
    func sample() -> (ws: Workspace, home1: PaneID, home2: PaneID, a1: PaneID) {
        var ws = Workspace()
        let a1 = ws.openTab(shell("A", "/repo/a"))
        let home1 = ws.openTab(session(.home, "h1"))
        ws.apply(event("SessionStart", "h1"), to: home1)
        let home2 = ws.openTab(shell(.home))
        ws.activate(.home)
        return (ws, home1, home2, a1)
    }

    // MARK: Space

    @Test func homeComesBeforeEveryPlot() {
        #expect([Space.plot("b"), .home, .plot("a")].sorted() == [.home, .plot("a"), .plot("b")])
        #expect(Space.home.plotID == nil && Space.home.isHome)
        #expect(Space.plot("a").plotID == "a" && !Space.plot("a").isHome)
    }

    // MARK: Workspace

    @Test func homeKeepsItsTabsApartFromThePlots() {
        var s = sample()
        #expect(s.ws.activeSpace == .home)
        #expect(s.ws.activePlotID == nil)
        #expect(s.ws.paneIDs(of: .home) == [s.home1, s.home2])
        #expect(s.ws.paneIDs(of: "A") == [s.a1])
        #expect(s.ws.focusedPane == s.home2)
        #expect(Set(s.ws.spacesWithPanes) == [.home, "A"])
        #expect(s.ws.plotIDsWithPanes == ["A"])

        // A split and a tab number act on Home only.
        let split = s.ws.split(in: .home, axis: .sideBySide, shell(.home))
        #expect(split != nil)
        #expect(s.ws.selectedTab(of: .home)?.tree.paneIDs.first == s.home2)
        #expect(s.ws.selectedTab(of: .home)?.tree.paneIDs.last == split)
        s.ws.selectTab(number: 1, in: .home)
        #expect(s.ws.focusedPane == s.home1)
        #expect(s.ws.selectedTabIndex(of: "A") == 0)

        // A plot that goes away leaves Home as it is.
        s.ws.removePlot("A")
        #expect(s.ws.paneIDs(of: .home).count == 3)
        #expect(s.ws.activeSpace == .home)
    }

    // MARK: Saved layout

    @Test func aHomePaneIsSavedWithAnEmptyPlotIDAndTheHomeKey() throws {
        let s = sample()
        let file = tempFile()
        let saved = SavedLayout(workspace: s.ws)
        try file.setValues(saved.jsonValues())
        #expect(SavedLayout.read(from: file) == saved)
        #expect(saved.layout.active == .home)
        #expect(saved.layout.activePlot == nil)
        #expect(saved.layout.home?.selected == 1)
        #expect(saved.layout.home?.tabs.map(\.focused) == [s.home1, s.home2])
        #expect(saved.layout.plots.keys.sorted() == ["A"])

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as! [String: Any]
        let panes = json["panes"] as! [[String: Any]]
        let home = panes.filter { $0["home"] as? Bool == true }
        #expect(home.count == 2)
        #expect(home.allSatisfy { $0["plot_id"] as? String == "" })
        #expect(panes.first { $0["home"] == nil }?["plot_id"] as? String == "A")
        let layout = json["layout"] as! [String: Any]
        #expect(layout["active_home"] as? Bool == true)
        #expect(layout["active_plot"] == nil)
        #expect(layout["home"] != nil)
        #expect((layout["plots"] as? [String: Any])?.keys.sorted() == ["A"])
    }

    /// A build before Home reads these keys: `plot_id` and `layout.plots`. The Home panes match no
    /// plot, so that build drops them and keeps the plot panes.
    @Test func aBuildBeforeHomeKeepsThePlotPanes() throws {
        let s = sample()
        let file = tempFile()
        try file.setValues(SavedLayout(workspace: s.ws).jsonValues())
        struct OldPane: Decodable { var id: PaneID; var plot_id: String }
        struct OldLayout: Decodable { var active_plot: String?; var plots: [String: SavedLayout.SpaceTabs] }
        struct OldState: Decodable { var panes: [OldPane]; var layout: OldLayout }
        let old = try JSONDecoder().decode(OldState.self, from: Data(contentsOf: file.url))
        #expect(old.layout.active_plot == nil)
        #expect(old.layout.plots["A"]?.tabs.flatMap(\.tree.paneIDs) == [s.a1])
        #expect(old.panes.filter { $0.plot_id == "A" }.map(\.id) == [s.a1])
    }

    @Test func aLayoutSavedBeforeHomeHasNoHome() throws {
        let file = tempFile()
        let pane = PaneID()
        try file.setValues([
            "panes": [["id": pane.uuidString, "plot_id": "A", "folder": "/repo/a", "kind": "shell"]],
            "layout": ["active_plot": "A",
                       "plots": ["A": ["selected": 0, "tabs": [["focused": pane.uuidString,
                                                                 "tree": ["leaf": ["_0": pane.uuidString]]]]]]],
        ])
        let saved = SavedLayout.read(from: file)
        #expect(saved.panes.map(\.space) == ["A"])
        #expect(saved.layout.active == "A")
        #expect(saved.layout.home == nil)
        #expect(saved.layout.spaces.map(\.space) == ["A"])
    }

    // MARK: Restore plan

    func restore(_ saved: SavedLayout, kept: Set<String>) -> RestorePlan {
        RestorePlan(saved, kept: kept, shown: kept) { pane in
            switch pane.kind {
            case .session: pane.sessionID.map { self.session(pane.space, $0) }
            case .shell: self.shell(pane.space, pane.folder ?? "~")
            }
        }
    }

    @Test func homeComesBackActiveAndIsNeverGone() {
        let s = sample()
        let plan = restore(SavedLayout(workspace: s.ws), kept: [])
        #expect(plan.droppedPlots == ["A"])
        #expect(plan.workspace.activeSpace == .home)
        #expect(plan.workspace.paneIDs(of: .home) == [s.home1, s.home2])
        #expect(plan.workspace.selectedTabIndex(of: .home) == 1)
        #expect(plan.workspace.session(of: s.home1)?.sessionID == "h1")
        #expect(!plan.workspace.isWaiting(.home))
    }

    @Test func homeWaitsWhenAPlotWasActive() {
        var s = sample()
        s.ws.activate("A")
        let plan = restore(SavedLayout(workspace: s.ws), kept: ["A"])
        #expect(plan.workspace.activeSpace == "A")
        #expect(plan.workspace.isWaiting(.home))
    }

    /// A pane record must match the space of its tab. A Home leaf with a plot record is dropped.
    @Test func aHomeLeafWithAPlotRecordIsDropped() {
        let s = sample()
        var saved = SavedLayout(workspace: s.ws)
        saved.panes[saved.panes.firstIndex { $0.id == s.home2 }!].space = "A"
        let plan = restore(saved, kept: ["A"])
        #expect(plan.workspace.paneIDs(of: .home) == [s.home1])
        #expect(plan.workspace.selectedTabIndex(of: .home) == 0)
    }

    @Test func theModelRestoresHomeAndResumesItsSessionInHome() throws {
        let file = tempFile()
        let s = sample()
        try file.setValues(SavedLayout(workspace: s.ws).jsonValues())
        let model = AppModel(stateFile: file)
        model.startRestore(from: file)
        model.apply([plot("A")])
        #expect(model.workspace.activeSpace == .home)
        let command = try #require(model.workspace.spec(of: s.home1)?.command)
        #expect(command.contains("start --home --resume h1"))
        #expect(model.workspace.spec(of: s.home2)?.folder == "~")
    }

    // MARK: The model

    @Test func withNoPlotHomeIsActiveAndATabOpensThere() throws {
        let model = AppModel(client: LoamClient())
        model.apply([])
        #expect(model.workspace.activeSpace == .home)
        model.openTab(.session)
        let pane = try #require(model.workspace.focusedPane)
        #expect(model.workspace.spec(of: pane)?.space == .home)
    }

    @Test func anActivePlotStaysActiveAndHomeStaysActiveWhenAPlotArrives() {
        let model = AppModel(client: LoamClient())
        model.apply([])
        model.apply([plot("A")])
        #expect(model.workspace.activeSpace == .home)
        model.activate(plot: "A")
        model.apply([plot("A"), plot("B")])
        #expect(model.workspace.activeSpace == "A")
    }

    /// A pane gets `HOME` from the user record, not from the app, so the app's `HOME` does not count.
    @Test func theHomeFolderIsTheUsersHomeFolder() {
        let model = AppModel(client: LoamClient(environment: ["HOME": "/tmp/elsewhere"]))
        #expect(model.homeFolder == NSHomeDirectory())
    }

    @Test func aHomeSessionStartsWithTheHomeFlagAndNoPlot() throws {
        let model = AppModel(client: LoamClient(binary: URL(fileURLWithPath: "/bin/loam")))
        model.shell = "/bin/zsh"
        let spec = model.newSessionSpec(in: .home)
        let id = try #require(spec.sessionID)
        #expect(spec.space == .home)
        #expect(spec.command == PaneCommand.startHome(shell: "/bin/zsh", loam: "/bin/loam", sessionID: id))
        #expect(spec.command?.contains("start --home --session-id \(id)") == true)
        #expect(spec.repo == nil && spec.worktree == nil && !spec.inPlotFolder)
        #expect(model.resumeSpec(in: .home, sessionID: id).command
            == PaneCommand.resumeHome(shell: "/bin/zsh", loam: "/bin/loam", sessionID: id))
    }

    @Test func aHomeShellStartsInTheHomeFolder() async throws {
        let model = AppModel(client: LoamClient())
        model.homeFolder = "/Users/me"
        #expect(await model.startFolder(of: .home) == "/Users/me")
        model.apply([plot("A")])
        model.activate(plot: "A")
        model.openHomeTab(.shell)
        #expect(model.workspace.activeSpace == .home)
        let pane = try #require(model.workspace.focusedPane)
        #expect(model.workspace.spec(of: pane)?.kind == .shell)
        #expect(model.workspace.spec(of: pane)?.folder == "/Users/me")
        #expect(model.workspace.paneIDs(of: "A").isEmpty)
    }

    @Test func newSessionInHomeFromAPlotOpensASessionInHome() throws {
        let model = AppModel(client: LoamClient())
        model.apply([plot("A")])
        model.activate(plot: "A")
        model.openTab(.shell)
        model.openHomeTab(.session)
        #expect(model.workspace.activeSpace == .home)
        let pane = try #require(model.workspace.focusedPane)
        #expect(model.workspace.spec(of: pane)?.kind == .session)
        #expect(model.workspace.spec(of: pane)?.command?.contains("start --home") == true)
        #expect(model.workspace.paneIDs(of: "A").count == 1)
    }

    @Test func spacesHaveNames() {
        let model = AppModel(client: LoamClient())
        model.apply([plot("A", "Alpha")])
        #expect(model.name(of: .home) == "Home")
        #expect(model.name(of: "A") == "Alpha")
        #expect(model.name(of: "gone") == nil)
    }

    @Test func aHomePaneThatNeedsYouCountsAsElsewhereFromAPlot() throws {
        let model = AppModel(client: LoamClient())
        model.apply([plot("A")])
        model.openHomeTab(.session)
        let home = try #require(model.workspace.focusedPane)
        let id = try #require(model.workspace.spec(of: home)?.sessionID)
        model.apply(event("PermissionRequest", id), to: home)
        #expect(model.elsewhereNeedYouCount == 0)
        #expect(model.nextPaneThatNeedsYou() == home)
        model.activate(plot: "A")
        #expect(model.elsewhereNeedYouCount == 1)
        #expect(model.nextPaneThatNeedsYou(elsewhere: true) == home)
        #expect(model.goToNextPaneThatNeedsYou(elsewhere: true))
        #expect(model.workspace.activeSpace == .home)
    }

    @Test func whenTheLastPlotGoesHomeIsActive() {
        let model = AppModel(client: LoamClient())
        model.apply([plot("A")])
        #expect(model.workspace.activeSpace == "A")
        model.apply([])
        #expect(model.workspace.activeSpace == .home)
    }

    // MARK: Sidebar

    @Test func theSidebarShowsHomeAboveThePlots() {
        var s = sample()
        s.ws.apply(event("PermissionRequest", "h1"), to: s.home1)
        let model = SidebarModel(plots: [plot("A", "Alpha")], workspace: s.ws, collapsed: false, arriving: [s.home1])
        #expect(model.home == .init(paneCount: 2, isActive: true, needsYouCount: 1, hasDoneUnread: false, isArriving: true))
        #expect(model.activeSpace == .home)
        #expect(model.activePlotID == nil)
        #expect(model.windowTitle == "Home")
        #expect(model.activePanes.map(\.id) == [s.home1, s.home2])
        #expect(model.homeTree.panes.map(\.id) == [s.home1, s.home2])
        #expect(model.selection == .pane(s.home2))
        #expect(model.needsYou.map(\.plotName) == ["Home"])
        #expect(model.needsYou.map(\.space) == [.home])
        #expect(model.elsewhereNeedYou == 0)
        #expect(model.withPanes.map(\.isActive) == [false])
    }

    @Test func theNeedsYouListPutsHomeFirst() {
        var s = sample()
        let a = s.ws.openTab(session("A", "a1"))
        s.ws.apply(event("PermissionRequest", "a1"), to: a)
        s.ws.apply(event("PermissionRequest", "h1"), to: s.home1)
        s.ws.activate("A")
        let model = SidebarModel(plots: [plot("A", "Alpha")], workspace: s.ws, collapsed: false)
        #expect(model.needsYou.map(\.id) == [s.home1, a])
        #expect(model.needsYou.map(\.plotName) == ["Home", "Alpha"])
        #expect(model.elsewhereNeedYou == 1)
        #expect(!model.home.isActive)
    }

    @Test func anEmptyHomeIsSelectedAsARow() {
        var ws = Workspace()
        ws.activate(.home)
        let model = SidebarModel(plots: [], workspace: ws, collapsed: false)
        #expect(model.selection == .home)
        #expect(model.home.paneCount == 0)
        #expect(model.homeTree.isEmpty)
    }

    @Test func homeOpensInTheTreeWhenItBecomesActive() {
        var disclosure = SidebarDisclosure()
        disclosure.activeSpaceChanged(to: "A")
        #expect(disclosure.isOpen("A"))
        disclosure.activeSpaceChanged(to: .home)
        #expect(disclosure.isOpen(.home))
        disclosure.setSpace(.home, open: false)
        #expect(!disclosure.isOpen(.home))
    }

    @Test func theTabBarShowsTheHomeTabs() {
        let s = sample()
        let bar = TabBarModel(workspace: s.ws, space: .home)
        #expect(bar.items.map(\.title) == ["claude", "shell"])
        #expect(bar.items.map(\.isSelected) == [false, true])
    }

    @Test func controlZeroSelectsHome() {
        #expect(LoamKeys.route(KeyChord(.control, "0"), isGhosttyBinding: true) == .loam(.selectHome))
        #expect(LoamKeys.chord(for: .selectHome) == KeyChord(.control, "0"))
    }
}
