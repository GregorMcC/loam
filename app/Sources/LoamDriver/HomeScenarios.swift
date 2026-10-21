import AppKit
import LoamKit
import LoamTerminal

/// Driver scenarios for ticket 99: Home, the space above the plots for tabs that belong to no plot.
/// The two scenarios are two app runs on one rig: `LOAM_DRIVER_RIG` names its folder, with a temp
/// store, a temp `state.json`, and a fake HOME. `claude` is the core's fake in hook mode
/// (`LOAM_DRIVER_FAKE_CLAUDE`, see the `panes` scenario).
@MainActor
extension Scenarios {
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    /// What the first run leaves for the second: the Home panes and their session IDs.
    private struct HomeSaved: Codable {
        var trees: [SplitTree]
        var sessionIDs: [String: String]  // Pane ID to session ID.
        var shell: PaneID
    }

    /// What the fake claude recorded about its last run.
    private struct HomeInvocation: Decodable {
        var args: [String]
        var env: [String: String]
        var cwd: String
    }

    @MainActor private struct HomeRig {
        let rig: PanelRig
        let environment: [String: String]
        var savedFile: URL { rig.root.appendingPathComponent("home-expect.json") }
        static let invocationName = "claude-invocation.json"
        var invocationFile: URL { rig.root.appendingPathComponent(Self.invocationName) }

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
                "LOAM_FAKE_CLAUDE_OUT": rig.root.appendingPathComponent(Self.invocationName).path,
                "LOAM_FAKE_CLAUDE_HOOKS": "1",
                "LOAM_FAKE_CLAUDE_TURN": "1s",
            ]) { $1 }
        }

        func launch(_ app: DriverApp) async throws -> AppHost {
            try await app.launchApp(client: LoamClient(binary: rig.binary, environment: environment),
                                    state: rig.stateFile, terminals: true)
        }

        func invocation() -> HomeInvocation? {
            (try? Data(contentsOf: invocationFile)).flatMap { try? JSONDecoder().decode(HomeInvocation.self, from: $0) }
        }
    }

    /// Calls the app's quit and waits for its answer.
    private static func quitHome(_ host: AppHost, _ app: DriverApp) async throws {
        var answer: Bool?
        host.quit { answer = $0 }
        try await app.waitUntil("quit answered", timeout: 15) { answer != nil }
        try expect(answer == true, "quit did not finish")
    }

    /// Run 1: a store with no plot opens Home. ⌘T starts a session there with no plot, ⌃0 comes
    /// back to Home from a plot, ⌘⌥T opens a shell in the home folder, and ⌘J "New session in
    /// Home" works from inside a plot. Quit writes the Home tabs to `state.json`.
    static func home(_ app: DriverApp) async throws {
        do { try await homeSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func homeSteps(_ app: DriverApp) async throws {
        let setup = try HomeRig(fresh: true)
        let host = try await setup.launch(app)
        let model = host.model
        // A pane gets HOME from the user record (see `AppModel.homeFolder`), so Home is your real home
        // folder, not the rig's fake HOME. The panes only start there: the fake claude writes nothing.
        let home = URL(fileURLWithPath: model.homeFolder).resolvingSymlinksInPath().path
        func homeTabs() -> [Tab] { model.workspace.tabs(of: .home) }
        func focused() -> PaneID? { model.workspace.selectedTab(of: .home)?.focused }
        func started(_ pane: PaneID) -> Bool { model.workspace.session(of: pane)?.started == true }

        // 1. No plot: Home is active, and the sidebar shows its row.
        try await app.waitUntil("Home is active") { model.workspace.activeSpace == .home }
        try await app.waitUntil("the Home row shows") { app.exists("home-row") }

        // 2. ⌘T starts a session in Home: the home folder, the pane socket, and no plot.
        try app.pressMenuKey("t")
        try await app.waitUntil("a session in Home") { focused() != nil }
        let session = focused()!
        let sessionID = try model.workspace.spec(of: session)?.sessionID ?? { throw DriverFailure("no session ID") }()
        try await app.waitUntil("the fake claude ran") { setup.invocation()?.args.contains(sessionID) == true }
        let start = setup.invocation()!
        Log.line("RESULT claude args: \(start.args.joined(separator: " "))")
        try expect(start.args.starts(with: ["--session-id", sessionID]), "claude did not get --session-id \(sessionID)")
        try expect(!start.args.contains("--add-dir"), "a Home session has an added folder")
        try expect(URL(fileURLWithPath: start.cwd).resolvingSymlinksInPath().path == home,
                   "the session runs in \(start.cwd), not \(home)")
        try expect(start.env["LOAM_PLOT"] == nil, "a Home session has LOAM_PLOT \(start.env["LOAM_PLOT"] ?? "")")
        let socket = start.env["LOAM_PANE_SOCKET"] ?? ""
        try expect(!socket.isEmpty && FileManager.default.fileExists(atPath: socket), "the session has no pane socket: \(socket)")
        try await app.waitUntil("SessionStart reached the pane") { started(session) }
        try await app.waitUntil("the window title is Home") { app.window.title == "Home" }

        // 3. Two plots arrive. Home stays active. ⌃0 comes back to Home from a plot.
        let first = try setup.rig.newPlot("Loam v1 build")
        _ = try setup.rig.newPlot("Release notes")
        try await app.waitUntil("the plots arrive", timeout: 10) { model.plots.count == 2 }
        try expect(model.workspace.activeSpace == .home, "a new plot took the active space from Home")
        model.activate(plot: first)
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == first }
        app.press(letter: "0", flags: .control)
        try await app.waitUntil("⌃0 selects Home") { model.workspace.activeSpace == .home }
        try await app.waitUntil("the Home session has the keys") { app.window.firstResponder === host.paneView(session) }

        // 4. ⌘⌥T opens a shell tab in the home folder.
        try app.pressMenuKey("t", flags: [.command, .option])
        try await app.waitUntil("a shell tab in Home") { homeTabs().count == 2 }
        let shell = focused()!
        try expect(model.workspace.spec(of: shell)?.kind == .shell, "⌘⌥T did not open a shell")
        guard let shellView = host.paneView(shell) as? TerminalSurfaceView else { throw DriverFailure("the shell has no terminal") }
        try await app.waitUntil("the shell has the keys") { app.window.firstResponder === shellView }
        try app.type("echo \"cwd=$(pwd -P) plot=${LOAM_PLOT:-none}\"")
        app.press(.returnKey)
        try await app.waitUntil("the shell output") { app.lines(shellView).contains("cwd=\(home) plot=none") }

        // 5. From inside a plot, ⌘J "New session in Home" opens a session in Home.
        model.activate(plot: first)
        try await app.waitUntil("the plot is active again") { model.workspace.activePlotID == first }
        model.openTab(.shell)
        try await app.waitUntil("a pane in the plot has the keys") {
            model.workspace.focusedPane.map { app.window.firstResponder === host.paneView($0) } ?? false
        }
        app.press(letter: "j", flags: .command)
        try await app.waitUntil("the menu opens") { app.exists("actions-menu") }
        try await app.waitUntil("the search field has the keys") { app.window.firstResponder is NSTextView }
        try app.type("session in home")
        try await app.waitUntil("the filter leaves New session in Home") {
            app.exists("actions-row-New session in Home") && !app.exists("actions-row-New shell in Home")
        }
        app.press(.returnKey)
        try await app.waitUntil("Return opens a session in Home", timeout: 10) {
            model.workspace.activeSpace == .home && homeTabs().count == 3 && !app.exists("actions-menu")
        }
        let second = focused()!
        try expect(model.workspace.spec(of: second)?.command?.contains("--home") == true, "the new session is not a Home session")
        try await app.waitUntil("the second Home session started") { started(second) }
        try expect(model.workspace.paneCount(of: .plot(first)) == 1, "the plot lost or gained a pane")

        // The sidebar with Home and two plots.
        await app.sleep(0.6)
        app.screenshot("home-sidebar")

        // 6. Quit writes the Home tabs and Home as the active space.
        var ids: [String: String] = [:]
        for pane in [session, second] { ids[pane.uuidString] = model.workspace.session(of: pane)?.sessionID }
        let saved = HomeSaved(trees: homeTabs().map(\.tree), sessionIDs: ids, shell: shell)
        try JSONEncoder().encode(saved).write(to: setup.savedFile)
        try await quitHome(host, app)
        let file = SavedLayout.read(from: setup.rig.stateFile)
        try expect(file.layout.active == .home, "state.json has the active space \(String(describing: file.layout.active))")
        try expect(file.layout.home?.tabs.map(\.tree) == saved.trees, "state.json has other Home tabs")
        try expect(file.panes.filter { $0.space == .home }.count == 3, "state.json has \(file.panes.count) panes")
        Log.line("RESULT Home sessions before quit: \(ids)")
    }

    /// Run 2: the same store and `state.json`. Home is active again, and each Home session resumes
    /// in the home folder with no session record.
    static func homeRelaunch(_ app: DriverApp) async throws {
        do { try await homeRelaunchSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func homeRelaunchSteps(_ app: DriverApp) async throws {
        let setup = try HomeRig(fresh: false)
        let saved = try JSONDecoder().decode(HomeSaved.self, from: Data(contentsOf: setup.savedFile))
        let host = try await setup.launch(app)
        let model = host.model
        try await app.waitUntil("Home is active") { model.workspace.activeSpace == .home }
        try expect(model.workspace.tabs(of: .home).map(\.tree) == saved.trees, "Home has another layout")

        for (pane, id) in saved.sessionIDs {
            let pane = try PaneID(uuidString: pane) ?? { throw DriverFailure("bad pane ID \(pane)") }()
            try expect(model.workspace.spec(of: pane)?.command?.contains("start --home --resume \(id)") == true,
                       "pane \(pane) does not resume \(id) in Home")
            try await app.waitUntil("session \(id) resumed") { model.workspace.session(of: pane)?.started == true }
            try expect(model.workspace.session(of: pane)?.sessionID == id, "pane \(pane) runs another session")
            guard let view = host.paneView(pane) as? TerminalSurfaceView else { throw DriverFailure("pane \(pane) has no terminal") }
            try await app.waitUntil("the resumed session text") { view.screenText().contains("fake claude: session \(id)") }
            Log.line("RESULT Home pane \(pane.uuidString) resumed \(id)")
        }
        let shell = model.workspace.spec(of: saved.shell)
        try expect(shell?.kind == .shell && shell?.folder == model.homeFolder, "the Home shell is not back in the home folder")
        app.screenshot("home-relaunch")
        try await quitHome(host, app)
    }
}
