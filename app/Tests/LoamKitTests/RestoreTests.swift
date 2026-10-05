import CoreGraphics
import Foundation
import Testing

@testable import LoamKit

/// Ticket 29: `state.json`, the restore plan, and the close and quit question.
@MainActor
@Suite struct RestoreTests {
    func tempFile() -> AppStateFile {
        AppStateFile(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("loam-restore-\(UUID().uuidString)/state.json"))
    }

    func event(_ name: String, _ id: String, cwd: String = "/repo/a") -> PaneEvent {
        PaneEvent(event: name, sessionID: id, cwd: cwd, at: "2026-10-03T09:00:00Z", source: nil, notificationType: nil)
    }

    func session(_ plot: String, _ id: String, repo: String? = nil) -> PaneSpec {
        PaneSpec(kind: .session, plot: plot, command: "loam start", title: "claude", repo: repo, sessionID: id)
    }

    func shell(_ plot: String, _ folder: String) -> PaneSpec {
        PaneSpec(kind: .shell, plot: plot, folder: folder, title: "shell")
    }

    func plot(_ id: String) -> PlotSummary {
        PlotSummary(id: id, name: id, what: "", createdAt: "2026-01-01T00:00:00Z")
    }

    /// 2 plots. A: tab 1 is a session split with a shell (ratio 0.3), tab 2 a session after /clear,
    /// tab 2 selected. B: one shell tab. A is active.
    func sample() -> (ws: Workspace, a1: PaneID, aShell: PaneID, a2: PaneID, bShell: PaneID) {
        var ws = Workspace()
        let a1 = ws.openTab(session("A", "s1"))
        ws.apply(event("SessionStart", "s1"), to: a1)
        let aShell = ws.split(plot: "A", axis: .sideBySide, shell("A", "/repo/a"))!
        ws.setRatio(0.3, at: [], plot: "A")
        ws.focus(a1)
        let a2 = ws.openTab(session("A", "s2", repo: "web"))
        ws.apply(event("SessionStart", "s2", cwd: "/repo/web"), to: a2)
        ws.apply(event("SessionStart", "s3", cwd: "/repo/web"), to: a2)  // /clear: a new ID.
        let bShell = ws.openTab(shell("B", "/repo/b"))
        ws.activate(plot: "A")
        return (ws, a1, aShell, a2, bShell)
    }

    // MARK: Encoding

    @Test func encodesEachPaneAndEachPlotLayout() throws {
        let s = sample()
        let saved = SavedLayout(workspace: s.ws, window: .init(frame: CGRect(x: 10, y: 20, width: 900, height: 600),
                                                              sidebarCollapsed: true, panelOpen: true))
        #expect(saved.panes.map(\.id) == [s.a1, s.aShell, s.a2, s.bShell])
        #expect(saved.panes[0] == .init(id: s.a1, plotID: "A", folder: "/repo/a", kind: .session, sessionID: "s1"))
        #expect(saved.panes[1] == .init(id: s.aShell, plotID: "A", folder: "/repo/a", kind: .shell))
        // The current session ID after /clear, and the folder where the session started.
        #expect(saved.panes[2] == .init(id: s.a2, plotID: "A", folder: "/repo/web", kind: .session, sessionID: "s3", repo: "web"))
        #expect(saved.layout.activePlot == "A")
        #expect(saved.layout.plots["A"]?.selected == 1)
        #expect(saved.layout.plots["A"]?.tabs.first?.focused == s.a1)
        #expect(saved.layout.plots["A"]?.tabs.first?.tree == s.ws.tabs(of: "A")[0].tree)
        #expect(saved.window?.rect == CGRect(x: 10, y: 20, width: 900, height: 600))
    }

    @Test func roundTripsStateJSONAndKeepsTheOtherKeys() throws {
        let file = tempFile()
        try file.setValue(["plot:A": 1_700_000_000.0], forKey: UseTimes.key)
        try file.setLastSeenChanges(["A": 7])
        let s = sample()
        var ws = s.ws
        ws.processExited(s.bShell)
        let saved = SavedLayout(workspace: ws, window: .init(frame: CGRect(x: 1, y: 2, width: 3, height: 4)))
        try file.setValues(saved.jsonValues())

        #expect(SavedLayout.read(from: file) == saved)
        #expect(file.lastSeenChanges() == ["A": 7])
        #expect((file.value(forKey: UseTimes.key) as? [String: Any])?.count == 1)

        // The contract shape that `loam worktree rm` reads: `panes[].plot_id` and `panes[].folder`.
        struct CorePane: Decodable { var plot_id: String; var folder: String }
        struct CoreState: Decodable { var panes: [CorePane] }
        let core = try JSONDecoder().decode(CoreState.self, from: Data(contentsOf: file.url))
        #expect(core.panes.map(\.plot_id) == ["A", "A", "A", "B"])
        #expect(core.panes.map(\.folder) == ["/repo/a", "/repo/a", "/repo/web", "/repo/b"])
    }

    @Test func aMissingOrDamagedFileGivesAnEmptyLayout() throws {
        let file = tempFile()
        #expect(SavedLayout.read(from: file) == SavedLayout())
        try file.setValue(["not": "a list"], forKey: "panes")
        try file.setValue([:] as [String: Any], forKey: "layout")
        #expect(SavedLayout.read(from: file).panes.isEmpty)
    }

    @Test func doneUnreadComesBack() throws {
        var ws = Workspace()
        let pane = ws.openTab(session("A", "s1"))
        var saved = SavedLayout(workspace: ws)
        saved.panes[0].doneUnread = true
        let plan = RestorePlan(saved, kept: ["A"], shown: ["A"]) { $0.kind == .session ? self.session("A", $0.sessionID!) : nil }
        #expect(plan.workspace.session(of: pane)?.doneUnread == true)
    }

    // MARK: Restore plan

    func restore(_ saved: SavedLayout, kept: Set<String>, shown: Set<String>? = nil) -> RestorePlan {
        RestorePlan(saved, kept: kept, shown: shown ?? kept) { pane in
            switch pane.kind {
            case .session: pane.sessionID.map { PaneSpec(kind: .session, plot: pane.plotID, command: "loam resume \($0)",
                                                          title: "claude", repo: pane.repo, sessionID: $0) }
            case .shell: self.shell(pane.plotID, pane.folder ?? "~")
            }
        }
    }

    @Test func restoresTabsSplitsFocusAndPaneIDs() {
        let s = sample()
        let plan = restore(SavedLayout(workspace: s.ws), kept: ["A", "B"])
        let ws = plan.workspace
        #expect(ws.activePlotID == "A")
        #expect(ws.tabs(of: "A").map(\.tree) == s.ws.tabs(of: "A").map(\.tree))
        #expect(ws.tabs(of: "A").map(\.focused) == s.ws.tabs(of: "A").map(\.focused))
        #expect(ws.selectedTabIndex(of: "A") == 1)
        #expect(ws.paneIDs(of: "B") == [s.bShell])
        // A session pane resumes its current session. A shell gets a fresh shell in its folder.
        #expect(ws.spec(of: s.a2)?.command == "loam resume s3")
        #expect(ws.spec(of: s.a2)?.repo == "web")
        #expect(ws.session(of: s.a2)?.sessionID == "s3")
        #expect(ws.session(of: s.a2)?.started == false)
        #expect(ws.state(of: s.a2) == .running)
        #expect(ws.spec(of: s.aShell)?.folder == "/repo/a")
        #expect(ws.spec(of: s.aShell)?.kind == .shell)
        #expect(plan.droppedPlots.isEmpty)
    }

    @Test func aPlotWaitsUntilItIsFirstShown() {
        let s = sample()
        var ws = restore(SavedLayout(workspace: s.ws), kept: ["A", "B"]).workspace
        #expect(!ws.isWaiting("A"))
        #expect(ws.isWaiting("B"))
        #expect(ws.waitingPaneIDs(of: "B") == [s.bShell])
        #expect(ws.waitingPaneIDs == [s.bShell])
        #expect(Set(ws.livePaneIDs) == [s.a1, s.aShell, s.a2])
        #expect(ws.folder(of: s.bShell) == "/repo/b")
        ws.activate(plot: "B")
        #expect(!ws.isWaiting("B"))
        #expect(ws.waitingPaneIDs.isEmpty)
        #expect(ws.livePaneIDs.count == 4)
        ws.activate(plot: "A")
        #expect(!ws.isWaiting("B"))
    }

    @Test func dropsThePanesOfAPlotThatIsGone() {
        let s = sample()
        let plan = restore(SavedLayout(workspace: s.ws), kept: ["B"])
        #expect(plan.workspace.paneIDs(of: "A").isEmpty)
        #expect(plan.droppedPlots == ["A"])
        #expect(plan.workspace.activePlotID == nil)
        #expect(plan.workspace.paneIDs(of: "B") == [s.bShell])
    }

    @Test func anArchivedPlotKeepsItsPanesAndWaits() {
        let s = sample()
        let plan = restore(SavedLayout(workspace: s.ws), kept: ["A", "B"], shown: ["B"])
        #expect(plan.workspace.activePlotID == nil)  // The app then activates the first plot of the list.
        #expect(plan.workspace.isWaiting("A"))
        #expect(plan.workspace.paneCount(of: "A") == 3)
    }

    @Test func dropsALeafWithNoPaneRecordAndATabThatEndsEmpty() {
        let s = sample()
        var saved = SavedLayout(workspace: s.ws)
        saved.panes.removeAll { $0.id == s.aShell || $0.id == s.a2 }
        let ws = restore(saved, kept: ["A", "B"]).workspace
        #expect(ws.tabs(of: "A").count == 1)
        #expect(ws.tabs(of: "A")[0].tree == .leaf(s.a1))
        #expect(ws.selectedTabIndex(of: "A") == 0)
    }

    @Test func aSessionPaneWithNoSessionIDIsDropped() {
        var ws = Workspace()
        let keep = ws.openTab(shell("A", "/x"))
        ws.openTab(PaneSpec(kind: .session, plot: "A", title: "claude"))
        ws.activate(plot: "A")
        let restored = restore(SavedLayout(workspace: ws), kept: ["A"]).workspace
        #expect(restored.paneIDs(of: "A") == [keep])
    }

    // MARK: The model

    @Test func theModelRestoresOnTheFirstPlotListAndWritesAfterEachLayoutChange() throws {
        let file = tempFile()
        let s = sample()
        try file.setValues(SavedLayout(workspace: s.ws, window: .init(sidebarCollapsed: true)).jsonValues())
        let before = try Data(contentsOf: file.url)

        let model = AppModel(stateFile: file)
        model.startRestore(from: file)
        #expect(model.restoredWindow?.sidebarCollapsed == true)
        model.sidebarCollapsed = true
        let writer = model.stateWriter!
        writer.flush()
        #expect(try Data(contentsOf: file.url) == before, "a write before the plot list arrived")

        model.apply([plot("A"), plot("B")])
        #expect(model.workspace.paneIDs(of: "A") == s.ws.paneIDs(of: "A"))
        #expect(model.workspace.isWaiting("B"))
        #expect(model.workspace.spec(of: s.a1)?.command?.contains("resume") == true)
        writer.flush()
        let writes = writer.writeCount

        // A hook line that changes only working or idle writes nothing.
        model.apply(event("UserPromptSubmit", "s1"), to: s.a1)
        writer.flush()
        #expect(writer.writeCount == writes)

        model.closePane(s.aShell)
        writer.flush()
        #expect(writer.writeCount == writes + 1)
        #expect(SavedLayout.read(from: file).panes.map(\.id) == [s.a1, s.a2, s.bShell])

        model.activate(plot: "B")
        writer.flush()
        #expect(SavedLayout.read(from: file).layout.activePlot == "B")
    }

    @Test func aPlotThatIsGoneAtLaunchLosesItsPanes() throws {
        let file = tempFile()
        let s = sample()
        try file.setValues(SavedLayout(workspace: s.ws).jsonValues())
        let model = AppModel(stateFile: file)
        model.startRestore(from: file)
        model.apply([plot("B")])
        #expect(model.workspace.paneIDs(of: "A").isEmpty)
        #expect(model.workspace.activePlotID == "B")
        #expect(!model.workspace.isWaiting("B"))
        model.stateWriter!.flush()
        #expect(SavedLayout.read(from: file).panes.map(\.plotID) == ["B"])
    }

    @Test func manyFocusChangesMakeOneWriteOffTheMainThread() async throws {
        let file = tempFile()
        try file.setLastSeenChanges(["A": 4])
        let model = AppModel(stateFile: file)
        model.startRestore(from: file, writeDelay: .milliseconds(200))
        let writer = model.stateWriter!
        model.useTimes = UseTimes(writer: writer)
        model.apply([plot("A")])
        model.openTab(.shell, folder: "/x")
        let left = model.workspace.selectedTab(of: "A")!.focused
        model.split(.sideBySide, .shell)
        let right = model.workspace.selectedTab(of: "A")!.focused
        writer.flush()
        let writes = writer.writeCount
        let before = try Data(contentsOf: file.url)

        // Rapid ⌘[ and ⌘]: each focus change records a use and changes the layout.
        for n in 0..<200 { model.focus(n.isMultiple(of: 2) ? left : right) }
        // Nothing is written yet: the writes wait, so the main thread does no disk work.
        #expect(try Data(contentsOf: file.url) == before)

        // One write takes every change. Wait with a long limit; the full suite runs in parallel.
        let deadline = ContinuousClock.now + .seconds(10)
        while writer.writeCount == writes, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(600))
        #expect(writer.writeCount == writes + 1)
        writer.flush()  // Waits for the background write to end.

        let saved = SavedLayout.read(from: file)
        #expect(saved.layout.plots["A"]?.tabs.first?.focused == right)
        let times = file.value(forKey: UseTimes.key) as? [String: Double]
        #expect(times?[SwitcherItem.paneKey(left.uuidString)] != nil)
        #expect(times?[SwitcherItem.paneKey(right.uuidString)] != nil)
        #expect(file.lastSeenChanges() == ["A": 4])
    }

    @Test func aFailedWriteIsTriedAgainAtTheNextWrite() async throws {
        let file = tempFile()
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        let writer = AppStateWriter(file: file, delay: .seconds(60))
        var ws = Workspace()
        let pane = ws.openTab(shell("A", "/x"))
        writer.layout = { SavedLayout(workspace: ws) }
        var count = 1
        writer.setChanged("count") { count }
        writer.setLayoutChanged()
        writer.flush()  // The file holds invalid JSON, so the write fails.
        #expect(try Data(contentsOf: file.url) == Data("not json".utf8))
        let deadline = ContinuousClock.now + .seconds(10)
        while !writer.hasPending, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(writer.hasPending)

        // The file is good again. Quit writes every key of the failed write, with its value now.
        try Data("{}".utf8).write(to: file.url)
        count = 2
        writer.suspend()
        #expect(file.value(forKey: "count") as? Int == 2)
        #expect(SavedLayout.read(from: file).panes.map(\.id) == [pane])
    }

    @Test func quitWritesEveryPendingChange() throws {
        let file = tempFile()
        let model = AppModel(stateFile: file)
        model.startRestore(from: file, writeDelay: .seconds(60))
        model.useTimes = UseTimes(writer: model.stateWriter!)
        model.apply([plot("A")])
        model.openTab(.shell, folder: "/x")
        let pane = model.workspace.selectedTab(of: "A")!.focused
        model.activate(plot: "A")
        model.windowFrame = CGRect(x: 1, y: 2, width: 800, height: 600)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        model.prepareForQuit()
        let saved = SavedLayout.read(from: file)
        #expect(saved.panes.map(\.id) == [pane])
        #expect(saved.window?.frame == [1, 2, 800, 600])
        #expect((file.value(forKey: UseTimes.key) as? [String: Double])?[SwitcherItem.plotKey("A")] != nil)
    }

    /// A pane row of the sidebar tree goes to the pane, and the switcher ranks it as used (ticket 71).
    @Test func goingToAPaneRecordsAUse() throws {
        let file = tempFile()
        let model = AppModel(stateFile: file)
        model.startRestore(from: file, writeDelay: .seconds(60))
        model.useTimes = UseTimes(writer: model.stateWriter!)
        model.apply([plot("A")])
        model.openTab(.shell, folder: "/x")
        let left = model.workspace.selectedTab(of: "A")!.focused
        model.split(.sideBySide, .shell)
        model.goToPane(left)
        #expect(model.workspace.focusedPane == left)
        model.prepareForQuit()
        #expect((file.value(forKey: UseTimes.key) as? [String: Double])?[SwitcherItem.paneKey(left.uuidString)] != nil)
    }

    @Test func aWaitingWorktreePaneCountsAsSavedUntilItsPlotShows() throws {
        let file = tempFile()
        let tree = WorktreeRef(id: "wtreeaaaab", name: "fix", branch: "fix", path: "/wt/web-fix")
        var ws = Workspace()
        ws.openTab(shell("A", "/repo/a"))
        let pane = ws.openTab(PaneSpec(kind: .session, plot: "B", title: "claude", sessionID: "s9", worktree: tree))
        ws.activate(plot: "A")
        try file.setValues(SavedLayout(workspace: ws).jsonValues())
        #expect(SavedLayout.read(from: file).panes.last?.worktree == tree)

        let model = AppModel(stateFile: file)
        model.startRestore(from: file)
        model.apply([plot("A"), plot("B")])
        #expect(model.workspace.spec(of: pane)?.worktree == tree)
        #expect(model.savedPaneFolders() == ["/wt/web-fix"])
        #expect(model.openPaneFolders == ["/repo/a"])
        model.activate(plot: "B")
        #expect(model.savedPaneFolders().isEmpty)
        #expect(Set(model.openPaneFolders) == ["/repo/a", "/wt/web-fix"])
    }

    @Test func quitKeepsThePanesInTheFile() throws {
        let file = tempFile()
        let model = AppModel(stateFile: file)
        model.startRestore(from: file)
        model.apply([plot("A")])
        model.openTab(.shell, folder: "/x")
        model.prepareForQuit()
        model.closeFocusedPane()
        #expect(SavedLayout.read(from: file).panes.count == 1)
        #expect(model.stateWriter?.isSuspended == true)
    }

    // MARK: The question

    @Test func asksOnlyWhenASessionIsMidTurn() {
        var ws = Workspace()
        let seeded = ws.openTab(session("A", "s1"))
        let sh = ws.openTab(shell("A", "/x"))
        #expect(ClosePrompt.make(.quit, closing: [seeded, sh], in: ws) == nil)  // Running, before SessionStart.
        ws.apply(event("SessionStart", "s1"), to: seeded)
        #expect(ClosePrompt.make(.pane, closing: [seeded], in: ws) == nil)  // Idle.
        ws.apply(event("UserPromptSubmit", "s1"), to: seeded)
        #expect(ClosePrompt.asks(for: seeded, in: ws))
        #expect(!ClosePrompt.asks(for: sh, in: ws))
        #expect(ClosePrompt.make(.pane, closing: [sh], in: ws) == nil)
        let quit = ClosePrompt.make(.quit, closing: [seeded, sh], in: ws)
        #expect(quit?.title == "Quit Loam?")
        #expect(quit?.message.hasPrefix("1 session is mid-turn.") == true)
        #expect(quit?.confirm == "Quit")
        #expect(ClosePrompt.make(.pane, closing: [seeded], in: ws)?.confirm == "Close")
        ws.apply(event("Stop", "s1"), to: seeded)
        #expect(ClosePrompt.make(.tab, closing: [seeded], in: ws) == nil)
        ws.apply(event("UserPromptSubmit", "s1"), to: seeded)
        ws.processExited(seeded)
        #expect(ClosePrompt.make(.quit, closing: [seeded], in: ws) == nil)  // Ended.
    }

    @Test func theQuestionCountsTheBusySessions() {
        var ws = Workspace()
        let panes = (1...2).map { i -> PaneID in
            let p = ws.openTab(session("A", "s\(i)"))
            ws.apply(event("UserPromptSubmit", "s\(i)"), to: p)
            return p
        }
        #expect(ClosePrompt.make(.quit, closing: panes, in: ws)?.message.hasPrefix("2 sessions are mid-turn.") == true)
        #expect(ClosePrompt.make(.tab, closing: panes, in: ws)?.message.hasPrefix("2 sessions in this tab") == true)
    }

    /// Spec 8.2: ⌘W and quit also ask when a session needs you (ticket 32).
    @Test func asksWhenASessionNeedsYou() {
        var ws = Workspace()
        let pane = ws.openTab(session("A", "s1"))
        ws.apply(event("SessionStart", "s1"), to: pane)
        ws.apply(event("UserPromptSubmit", "s1"), to: pane)
        ws.apply(event("PermissionRequest", "s1"), to: pane)
        #expect(ClosePrompt.asks(for: pane, in: ws))
        #expect(ClosePrompt.make(.pane, closing: [pane], in: ws)?.message.hasPrefix("The session in this pane needs you.") == true)
        #expect(ClosePrompt.make(.quit, closing: [pane], in: ws)?.message.hasPrefix("1 session needs you.") == true)
        #expect(ClosePrompt.make(.archive, closing: [pane], in: ws)?.message.hasPrefix("1 session in this plot needs you.") == true)
        let other = ws.openTab(session("A", "s2"))
        ws.apply(event("SessionStart", "s2"), to: other)
        ws.apply(event("UserPromptSubmit", "s2"), to: other)
        let both = ClosePrompt.make(.quit, closing: [pane, other], in: ws)
        #expect(both?.message.hasPrefix("1 session is mid-turn and 1 needs you. If you quit, the sessions stop") == true)
        // A key in the pane clears needs you, and the session is mid-turn again.
        ws.typed(in: pane)
        #expect(ClosePrompt.make(.tab, closing: [pane], in: ws)?.message.hasPrefix("1 session in this tab is mid-turn.") == true)
        // An API error ends the turn, but the pane needs you, so the question still shows.
        ws.apply(event("StopFailure", "s1"), to: pane)
        #expect(ClosePrompt.asks(for: pane, in: ws))
    }
}
