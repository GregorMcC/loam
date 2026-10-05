import AppKit
import LoamKit
import LoamTerminal

/// Driver scenarios for ticket 29: quit with 2 plots of panes, then relaunch and see each session
/// resume when its plot shows. The two scenarios are two app runs on one rig: `LOAM_DRIVER_RIG`
/// names its folder, with a temp store, a temp `state.json`, and a fake HOME. `claude` is the
/// core's fake in hook mode (`LOAM_DRIVER_FAKE_CLAUDE`, see the `panes` scenario).
@MainActor
extension Scenarios {
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    /// What the first run leaves for the second: the plots, the panes, and their session IDs.
    private struct Saved: Codable {
        var first: String
        var second: String
        var firstSession: PaneID
        var firstShell: PaneID
        var secondSession: PaneID
        var sessionIDs: [String: String]  // Pane ID to session ID.
        var shellFolder: String
        var trees: [String: [SplitTree]]  // Plot ID to its tab trees.
    }

    @MainActor private struct RestoreRig {
        let rig: PanelRig
        let environment: [String: String]
        var savedFile: URL { rig.root.appendingPathComponent("restore-expect.json") }

        init(fresh: Bool) throws {
            let env = ProcessInfo.processInfo.environment
            guard let folder = env["LOAM_DRIVER_RIG"] else { throw DriverFailure("LOAM_DRIVER_RIG does not name the rig folder") }
            guard let fake = env["LOAM_DRIVER_FAKE_CLAUDE"] else {
                throw DriverFailure("LOAM_DRIVER_FAKE_CLAUDE does not name the fake claude")
            }
            rig = try PanelRig(root: URL(fileURLWithPath: folder), fresh: fresh)
            let fm = FileManager.default
            let bin = rig.root.appendingPathComponent("bin")
            if fresh {
                try fm.createDirectory(at: bin, withIntermediateDirectories: true)
                try fm.copyItem(atPath: fake, toPath: bin.appendingPathComponent("claude").path)
                try "".write(to: rig.fakeHome.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            }
            environment = rig.environment.merging([
                "PATH": bin.path + ":" + (env["PATH"] ?? "/usr/bin:/bin"),
                "LOAM_FAKE_CLAUDE_OUT": rig.root.appendingPathComponent("claude-invocation.json").path,
                "LOAM_FAKE_CLAUDE_HOOKS": "1",
                "LOAM_FAKE_CLAUDE_TURN": "3s",
            ]) { $1 }
        }

        func launch(_ app: DriverApp) async throws -> AppHost {
            try await app.launchApp(client: LoamClient(binary: rig.binary, environment: environment),
                                    state: rig.stateFile, terminals: true)
        }
    }

    /// Calls the app's quit and waits for its answer.
    private static func quit(_ host: AppHost, _ app: DriverApp, cancelQuestion: Bool = false) async throws -> Bool {
        var answer: Bool?
        host.quit { answer = $0 }
        if cancelQuestion {
            try await app.waitUntil("the quit question") { app.window.attachedSheet != nil }
            guard let sheet = app.window.attachedSheet, let cancel = button("Cancel", in: sheet.contentView) else {
                throw DriverFailure("the quit question has no Cancel button")
            }
            app.screenshot("quit-question")
            cancel.performClick(nil)
        }
        try await app.waitUntil("quit answered", timeout: 15) { answer != nil }
        return answer!
    }

    private static func button(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(title, in: $0) }.first
    }

    /// Run 1: 2 plots with panes. A mid-turn session makes quit ask, and Cancel keeps every pane.
    /// Then quit closes every pane, and `state.json` holds them.
    static func restoreQuit(_ app: DriverApp) async throws {
        do { try await restoreQuitSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func restoreQuitSteps(_ app: DriverApp) async throws {
        let setup = try RestoreRig(fresh: true)
        let first = try setup.rig.newPlot("Restore one")
        let second = try setup.rig.newPlot("Restore two")
        let host = try await setup.launch(app)
        let model = host.model
        try await app.waitUntil("the first plot is active") { model.workspace.activePlotID == first }
        func focused(_ plot: String) -> PaneID? { model.workspace.selectedTab(of: plot)?.focused }
        func started(_ pane: PaneID) -> Bool { model.workspace.session(of: pane)?.started == true }

        // Plot 1: a session tab, split with a shell.
        try app.pressMenuKey("t")
        try await app.waitUntil("a seeded pane") { focused(first) != nil }
        let firstSession = focused(first)!
        try await app.waitUntil("the first session started") { started(firstSession) }
        await model.splitShell(.sideBySide)
        try await app.waitUntil("a shell split") { model.workspace.paneCount(of: first) == 2 }
        let firstShell = focused(first)!
        try expect(model.workspace.spec(of: firstShell)?.kind == .shell, "the split is not a shell")

        // Plot 2: a session tab.
        model.activate(plot: second)
        try app.pressMenuKey("t")
        try await app.waitUntil("a seeded pane in plot 2") { focused(second) != nil }
        let secondSession = focused(second)!
        try await app.waitUntil("the second session started") { started(secondSession) }

        // A prompt makes the session mid-turn. Quit asks, and Cancel keeps every pane.
        try await app.waitUntil("the terminal has the keys") { app.window.firstResponder is TerminalSurfaceView }
        try app.type("hello")
        app.press(.returnKey)
        try await app.waitUntil("working") { model.workspace.state(of: secondSession) == .working }
        try expect(try await !quit(host, app, cancelQuestion: true), "Cancel did not stop the quit")
        try expect(model.workspace.livePaneIDs.count == 3 && host.paneView(secondSession) != nil, "Cancel closed a pane")
        try await app.waitUntil("idle", timeout: 10) { model.workspace.state(of: secondSession) == .idle }

        // Plot 1 is active at the quit, so plot 2 waits at the next launch.
        model.activate(plot: first)
        var ids: [String: String] = [:]
        for pane in [firstSession, secondSession] {
            ids[pane.uuidString] = model.workspace.session(of: pane)?.sessionID
        }
        let saved = Saved(
            first: first, second: second, firstSession: firstSession, firstShell: firstShell, secondSession: secondSession,
            sessionIDs: ids, shellFolder: model.workspace.spec(of: firstShell)?.folder ?? "",
            trees: [first: model.workspace.tabs(of: first).map(\.tree), second: model.workspace.tabs(of: second).map(\.tree)])
        try JSONEncoder().encode(saved).write(to: setup.savedFile)
        Log.line("RESULT sessions before quit: \(ids)")

        // No session is mid-turn now, so quit asks nothing and closes every pane.
        try expect(try await quit(host, app), "quit did not finish")
        try expect(app.window.attachedSheet == nil, "quit asked with no session mid-turn")
        for pane in [firstSession, firstShell, secondSession] {
            try expect(host.paneView(pane) == nil, "pane \(pane) still has a view after quit")
        }
        let file = SavedLayout.read(from: setup.rig.stateFile)
        try expect(Set(file.panes.map(\.id)) == [firstSession, firstShell, secondSession],
                   "state.json lists \(file.panes.map(\.id)) after quit")
        try expect(file.layout.activePlot == first, "state.json has the active plot \(file.layout.activePlot ?? "none")")
    }

    /// Run 2: the same store and `state.json`. The active plot's session resumes at launch. The other
    /// plot waits, and its session resumes when the plot shows.
    static func restoreRelaunch(_ app: DriverApp) async throws {
        do { try await restoreRelaunchSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func restoreRelaunchSteps(_ app: DriverApp) async throws {
        let setup = try RestoreRig(fresh: false)
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: setup.savedFile))
        let host = try await setup.launch(app)
        let model = host.model
        func session(_ pane: PaneID) -> PaneSession? { model.workspace.session(of: pane) }
        func surface(_ pane: PaneID) throws -> TerminalSurfaceView {
            guard let view = host.paneView(pane) as? TerminalSurfaceView else { throw DriverFailure("pane \(pane) has no terminal") }
            return view
        }
        func resumed(_ pane: PaneID) async throws {
            let id = saved.sessionIDs[pane.uuidString]!
            try expect(model.workspace.spec(of: pane)?.command?.contains("resume") == true, "pane \(pane) does not run loam resume")
            try await app.waitUntil("session \(id) resumed") { session(pane)?.started == true }
            try expect(session(pane)?.sessionID == id, "pane \(pane) runs \(session(pane)?.sessionID ?? "none"), not \(id)")
            let view = try surface(pane)
            try await app.waitUntil("the resumed session text") { view.screenText().contains("fake claude: session \(id)") }
            Log.line("RESULT pane \(pane.uuidString) resumed \(id)")
        }

        try await app.waitUntil("the first plot is active") { model.workspace.activePlotID == saved.first }
        try expect(model.workspace.tabs(of: saved.first).map(\.tree) == saved.trees[saved.first], "plot 1 has another layout")
        try expect(model.workspace.tabs(of: saved.second).map(\.tree) == saved.trees[saved.second], "plot 2 has another layout")

        // Plot 1 shows: its session resumes, and its shell starts in the same folder.
        try await resumed(saved.firstSession)
        let shell = model.workspace.spec(of: saved.firstShell)
        try expect(shell?.kind == .shell && shell?.folder == saved.shellFolder, "the shell pane is not back in \(saved.shellFolder)")
        try expect(host.paneView(saved.firstShell) is TerminalSurfaceView, "the shell pane has no terminal")

        // Plot 2 waits: no terminal and no session until it shows.
        try expect(model.workspace.isWaiting(saved.second), "plot 2 does not wait")
        try expect(host.paneView(saved.secondSession) == nil, "plot 2's pane started before its plot showed")
        app.screenshot("relaunch-plot-1")
        model.activate(plot: saved.second)
        try await resumed(saved.secondSession)
        app.screenshot("relaunch-plot-2")

        try expect(try await quit(host, app), "quit did not finish")
    }
}
