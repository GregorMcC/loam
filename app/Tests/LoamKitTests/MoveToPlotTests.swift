import Foundation
import Testing

@testable import LoamKit

/// Ticket 100: a Home tab moves to a plot with all its panes. A shell keeps its process, and a
/// session continues its conversation in the plot.
@MainActor
@Suite(.temporaryFolders) struct MoveToPlotTests {
    func session(_ space: Space, _ id: String) -> PaneSpec {
        PaneSpec(kind: .session, space: space, command: "loam start --home", title: "claude", sessionID: id)
    }

    func shell(_ space: Space) -> PaneSpec {
        PaneSpec(kind: .shell, space: space, folder: "/Users/me", title: "shell")
    }

    func event(_ name: String, _ id: String) -> PaneEvent {
        PaneEvent(event: name, sessionID: id, cwd: "/Users/me", at: "2026-10-21T09:00:00Z", source: nil, notificationType: nil)
    }

    func plot(_ id: String, _ name: String) -> PlotSummary {
        PlotSummary(id: id, name: name, what: "", createdAt: "2026-01-01T00:00:00Z")
    }

    /// Home has 3 tabs: a shell, a shell with a session split (focused on the shell), and a session.
    /// The middle tab is selected. Plot A has one shell tab and is active.
    func sample() -> (ws: Workspace, moving: Tab, shell: PaneID, claude: PaneID) {
        var ws = Workspace()
        ws.openTab(shell("A"))
        ws.openTab(shell(.home))
        let shellPane = ws.openTab(shell(.home))
        let claude = ws.split(in: .home, axis: .sideBySide, session(.home, "h1"))!
        ws.focus(shellPane)
        ws.openTab(session(.home, "h2"))
        ws.selectTab(index: 1, in: .home)
        ws.activate("A")
        return (ws, ws.selectedTab(of: .home)!, shellPane, claude)
    }

    // MARK: Workspace

    @Test func theTabMovesWithItsTreeAndFocusAndTheTargetShowsIt() {
        var s = sample()
        let moved = s.ws.moveTab(s.moving.id, to: "A")
        #expect(moved)
        #expect(s.ws.tabs(of: "A").count == 2)
        #expect(s.ws.selectedTab(of: "A") == s.moving)
        #expect(s.ws.activeSpace == "A")
        #expect(s.ws.focusedPane == s.shell)
        #expect(s.ws.spec(of: s.shell)?.space == "A")
        #expect(s.ws.spec(of: s.claude)?.space == "A")
        #expect(s.ws.session(of: s.claude)?.sessionID == "h1")
        #expect(s.ws.launch(of: s.shell) == 0)
        #expect(!s.ws.paneIDs(of: .home).contains(s.shell))
    }

    @Test func homeSelectsTheNextTabAsAClose() {
        var s = sample()
        let next = s.ws.tabs(of: .home)[2]
        s.ws.moveTab(s.moving.id, to: "A")
        #expect(s.ws.tabs(of: .home).count == 2)
        #expect(s.ws.selectedTab(of: .home) == next)

        // The last tab of Home leaves Home with no selection.
        var one = Workspace()
        let pane = one.openTab(shell(.home))
        one.moveTab(one.selectedTab(of: .home)!.id, to: "B")
        #expect(one.tabs(of: .home).isEmpty)
        #expect(one.selectedTab(of: .home) == nil)
        #expect(one.paneIDs(of: "B") == [pane])
        #expect(one.activeSpace == "B")
    }

    @Test func aTabBeforeTheSelectionKeepsTheSameTabSelected() {
        var s = sample()
        let first = s.ws.tabs(of: .home)[0]
        s.ws.moveTab(first.id, to: "A")
        #expect(s.ws.selectedTab(of: .home) == s.moving)
    }

    /// A plot restored from `state.json` that waits starts its panes, and the moved panes stay live.
    @Test func aWaitingPlotStartsAndTheMovedPanesStayLive() {
        var ws = Workspace()
        let saved = PaneID()
        ws.restore("B", tabs: [Tab(id: UUID(), tree: .leaf(saved), focused: saved)], selected: 0,
                   specs: [saved: shell("B")], sessions: [saved: PaneSession(sessionID: nil)])
        let pane = ws.openTab(shell(.home))
        ws.activate(.home)
        #expect(ws.isWaiting("B"))
        ws.moveTab(ws.selectedTab(of: .home)!.id, to: "B")
        #expect(!ws.isWaiting("B"))
        #expect(Set(ws.livePaneIDs) == [saved, pane])
    }

    @Test func anUnknownTabOrTheSameSpaceChangesNothing() {
        var s = sample()
        let before = s.ws
        let unknown = s.ws.moveTab(UUID(), to: "A")
        let same = s.ws.moveTab(s.moving.id, to: .home)
        #expect(!unknown && !same)
        #expect(s.ws == before)
    }

    // MARK: The question

    @Test func aMoveAsksOnlyForASessionMidTurnOrThatNeedsYou() {
        var s = sample()
        let panes = s.moving.tree.paneIDs
        #expect(ClosePrompt.make(.move, closing: panes, in: s.ws) == nil)
        s.ws.apply(event("SessionStart", "h1"), to: s.claude, now: anyTime)
        s.ws.apply(event("UserPromptSubmit", "h1"), to: s.claude, now: anyTime)
        let prompt = ClosePrompt.make(.move, closing: panes, in: s.ws)
        #expect(prompt?.title == "Move this tab?")
        #expect(prompt?.confirm == "Move")
        #expect(prompt?.message.contains("1 session in this tab is mid-turn.") == true)
        #expect(prompt?.message.contains("resumes the session in the plot") == true)
    }

    // MARK: The pane command

    @Test func theCommandResumesTheSessionIntoThePlot() {
        #expect(PaneCommand.resumeInPlot(shell: "/bin/zsh", loam: "/bin/loam", sessionID: "s1", plot: "plotaaaaab")
            == "/bin/zsh -lc 'exec /bin/loam resume s1 --plot plotaaaaab'")
    }

    // MARK: The model

    /// Plots B and A (in that order) with no panes. Home is active with a tab of a shell and a
    /// started session split, focused on the session.
    func model(_ client: LoamClient = LoamClient(binary: URL(fileURLWithPath: "/bin/loam")))
        -> (model: AppModel, tab: UUID, shell: PaneID, claude: PaneID) {
        let model = AppModel(client: client)
        model.shell = "/bin/zsh"
        model.homeFolder = "/Users/me"
        model.apply([plot("plotaaaaab", "B"), plot("plotaaaaac", "A")])
        model.activateHome()
        model.openHomeTab(.shell)
        let shell = model.workspace.focusedPane!
        model.split(.sideBySide, .session)
        let claude = model.workspace.focusedPane!
        let first = model.workspace.spec(of: claude)!.sessionID!
        model.apply(event("SessionStart", first), to: claude)
        return (model, model.workspace.selectedTab(of: .home)!.id, shell, claude)
    }

    @Test func theTargetsAreThePlotsInSidebarOrder() {
        let m = model()
        #expect(m.model.moveTargets.map(\.id) == ["plotaaaaab", "plotaaaaac"])
        m.model.activate(plot: "plotaaaaac")
        m.model.openTab(.shell)
        // A plot with panes comes first in the sidebar.
        #expect(m.model.moveTargets.map(\.id) == ["plotaaaaac", "plotaaaaab"])
    }

    @Test func theSessionRestartsInThePlotAndTheShellKeepsRunning() throws {
        let m = model()
        let shellSpec = m.model.workspace.spec(of: m.shell)!
        // /clear gives the session a new ID. The move resumes the ID that the pane has now.
        m.model.apply(event("SessionStart", "now-id"), to: m.claude)
        #expect(m.model.moveToPlot(tab: m.tab, plot: "plotaaaaac"))

        #expect(m.model.workspace.activeSpace == "plotaaaaac")
        #expect(m.model.workspace.selectedTab(of: "plotaaaaac")?.id == m.tab)
        #expect(m.model.workspace.focusedPane == m.claude)
        #expect(m.model.workspace.tabs(of: .home).isEmpty)

        var movedShell = shellSpec
        movedShell.space = "plotaaaaac"
        #expect(m.model.workspace.spec(of: m.shell) == movedShell)
        #expect(m.model.workspace.launch(of: m.shell) == 0)

        let spec = try #require(m.model.workspace.spec(of: m.claude))
        #expect(m.model.workspace.launch(of: m.claude) == 1)
        #expect(spec.space == "plotaaaaac")
        #expect(spec.kind == .session)
        #expect(spec.command == "/bin/zsh -lc 'exec /bin/loam resume now-id --plot plotaaaaac'")
        #expect(spec.folder == "/Users/me")
        #expect(spec.sessionID == "now-id")
        #expect(spec.inPlotFolder)
        #expect(spec.repo == nil && spec.worktree == nil)
        #expect(m.model.workspace.session(of: m.claude)?.sessionID == "now-id")
    }

    @Test func onlyAHomeTabMovesAndOnlyToAPlotInTheList() {
        let m = model()
        #expect(!m.model.moveToPlot(tab: m.tab, plot: "nowhere"))
        #expect(!m.model.moveToPlot(tab: UUID(), plot: "plotaaaaab"))
        #expect(m.model.workspace.activeSpace == .home)

        m.model.activate(plot: "plotaaaaab")
        m.model.openTab(.shell)
        let plotTab = m.model.workspace.selectedTab(of: "plotaaaaab")!.id
        #expect(!m.model.moveToPlot(tab: plotTab, plot: "plotaaaaac"))
        #expect(m.model.workspace.tabs(of: "plotaaaaac").isEmpty)
    }

    /// The tab context menu and the sidebar can move a Home tab while a plot is active.
    @Test func aHomeTabMovesFromAnotherSpace() {
        let m = model()
        m.model.activate(plot: "plotaaaaab")
        #expect(m.model.moveToPlot(tab: m.tab, plot: "plotaaaaac"))
        #expect(m.model.workspace.activeSpace == "plotaaaaac")
        #expect(m.model.workspace.selectedTab(of: "plotaaaaac")?.id == m.tab)
    }

    @Test func thePromptCoversTheSessionsOfTheTab() {
        let m = model()
        #expect(m.model.movePrompt(tab: m.tab) == nil)
        let id = m.model.workspace.session(of: m.claude)!.sessionID!
        m.model.apply(event("UserPromptSubmit", id), to: m.claude)
        #expect(m.model.movePrompt(tab: m.tab)?.confirm == "Move")
    }

    @Test func newPlotMakesThePlotThenMovesTheTab() async throws {
        let fake = try FakeLoam([("new_app", 0), ("list", 0)])
        let m = model(fake.client())
        await m.model.moveToNewPlot(tab: m.tab, named: " Loam ")
        #expect(fake.args().first == "new Loam --json --actor app")
        #expect(m.model.workspace.activeSpace == "plotaaaaac")
        #expect(m.model.workspace.selectedTab(of: "plotaaaaac")?.id == m.tab)
    }

    /// The tab closed while the name sheet showed: no plot is made.
    @Test func newPlotForATabThatLeftHomeMakesNoPlot() async throws {
        let fake = try FakeLoam([("new_app", 0), ("list", 0)])
        let m = model(fake.client())
        m.model.closeTab(m.tab)
        await m.model.moveToNewPlot(tab: m.tab, named: "Loam")
        #expect(fake.args().isEmpty)
    }

    @Test func aFailedNewPlotMovesNothing() async throws {
        let fake = try FakeLoam([("error_generic", 1)])
        let m = model(fake.client())
        await m.model.moveToNewPlot(tab: m.tab, named: "Loam")
        #expect(m.model.lastError != nil)
        #expect(m.model.workspace.activeSpace == .home)
        #expect(m.model.workspace.tabs(of: .home).map(\.id) == [m.tab])
    }

    // MARK: The actions menu

    @Test func moveIsAvailableOnlyForATabInHome() {
        for command in [AppCommand.moveTabToPlot("p"), .moveTabToNewPlot] {
            #expect(ActionMenu.isAvailable(command, hasSpace: true, hasPlot: false, hasPane: true))
            #expect(!ActionMenu.isAvailable(command, hasSpace: true, hasPlot: true, hasPane: true))
            #expect(!ActionMenu.isAvailable(command, hasSpace: true, hasPlot: false, hasPane: false))
            #expect(!ActionMenu.isAvailable(command, hasSpace: false, hasPlot: false, hasPane: false))
        }
    }

    @Test func theMenuListsEachPlotThenNewPlot() {
        let targets = [plot("p2", "Beta"), plot("p1", "Beta")]
        let sections = ActionMenu.sections(paneTitle: "shell", plotName: nil, inHome: true, moveTargets: targets,
                                           chord: { _ in nil }, isEnabled: { _ in true })
        let move = sections.first { $0.id == "move" }
        #expect(move?.title == "Move to Plot")
        #expect(move?.items.map(\.command) == [.moveTabToPlot("p2"), .moveTabToPlot("p1"), .moveTabToNewPlot])
        #expect(move?.items.map(\.title) == ["Move to Beta", "Move to Beta", "Move to New Plot…"])
        // Two plots with one name are still two rows.
        #expect(Set(move?.items.map(\.id) ?? []).count == 3)
        #expect(ActionMenu.filter(sections, query: "move beta").first?.items.count == 2)
    }

    @Test func outsideHomeTheMenuHasNoMoveSection() {
        let sections = ActionMenu.sections(paneTitle: "shell", plotName: "Loam", moveTargets: [plot("p1", "Beta")],
                                           chord: { _ in nil }, isEnabled: { _ in true })
        #expect(!sections.contains { $0.id == "move" })
    }
}
