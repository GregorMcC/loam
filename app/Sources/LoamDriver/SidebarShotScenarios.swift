import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 86: the sidebar with the search button, the two attention rows, and
/// muted rows, in Night, Day, a third-party theme (Catppuccin Mocha), and translucent at 0.8.
/// A click on each attention row goes to the next pane in that state. The panes run the frame-shot demo script.
@MainActor
extension Scenarios {
    private static func want(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    private static func paneEvent(_ name: String) throws -> PaneEvent {
        let json = #"{"event":"\#(name)","session_id":"x","cwd":"/tmp","at":"2026-10-04T09:00:00Z"}"#
        return try JSONDecoder().decode(PaneEvent.self, from: Data(json.utf8))
    }

    static func sidebarShot(_ app: DriverApp) async throws {
        do { try await sidebarShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func sidebarShotSteps(_ app: DriverApp) async throws {
        let fm = FileManager.default
        let (rig, environment, config) = try shotRig(app)
        // The fake claude of the rig exits at once. Here it stays, so each session pane keeps its state.
        let claude = rig.root.appendingPathComponent("bin/claude")
        try (try String(contentsOf: claude, encoding: .utf8) + "case \"$1\" in mcp) exit 0 ;; esac\nexec sleep 600\n").write(to: claude, atomically: true, encoding: .utf8)
        let plot = try rig.newPlot("Loam v1 build")
        let repo = rig.root.appendingPathComponent("loam")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try rig.loam(["repo", "add", plot, repo.path])
        _ = try rig.newPlot("Recipe manager")
        _ = try rig.newPlot("Client onboarding")
        _ = try rig.newPlot("Release notes")

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        try await app.waitUntil("a plot is active") { host.model.workspace.activePlotID != nil }
        let model = host.model
        // Plot 1: a split tab and a session. Plot 2: two panes. Plot 3: one pane. Plot 4 has none.
        model.activate(number: 1)
        model.openTab()
        model.split(.sideBySide)
        model.openTab(.session)
        model.activate(number: 2)
        model.openTab(.session)
        model.openTab(.session)
        model.activate(number: 3)
        model.openTab(.session)
        model.activate(number: 1)
        model.selectTab(number: 1)
        try await app.waitUntil("2 demo panes ran", timeout: 15) {
            ((try? fm.contentsOfDirectory(atPath: "\(app.outFolder)/demo-runs"))?.count ?? 0) >= 2
        }
        let sidebar = model.sidebar
        let second = sidebar.withPanes[1].id, third = sidebar.withPanes[2].id
        let panesTwo = model.workspace.paneIDs(of: second)
        let paneThree = model.workspace.paneIDs(of: third)[0]
        try want(model.sidebar.needsYouCount == 0 && model.sidebar.doneUnreadCount == 0, "a pane is in a state at the start")
        // A pane starts its session when its plot first shows.
        model.activate(number: 2)
        await app.sleep(1.5)
        model.activate(number: 3)
        await app.sleep(1.5)
        model.activate(number: 1)
        await app.sleep(1)
        // SessionStart gives each pane the session ID that the later events carry.
        for pane in panesTwo + [paneThree] { model.apply(try paneEvent("SessionStart"), to: pane) }
        model.apply(try paneEvent("PermissionRequest"), to: panesTwo[0])
        model.apply(try paneEvent("PermissionRequest"), to: paneThree)
        model.apply(try paneEvent("Stop"), to: panesTwo[1])
        Log.line("RESULT counts \(model.sidebar.needsYouCount) \(model.sidebar.doneUnreadCount), kinds \((panesTwo + [paneThree]).map { String(describing: model.workspace.spec(of: $0)?.kind) }), text \(app.text(of: "attention-needs-you") ?? "nil")")
        try await app.waitUntil("the counts show") {
            model.sidebar.needsYouCount == 2 && model.sidebar.doneUnreadCount == 1
                && app.text(of: "attention-needs-you")?.contains("2") == true
        }

        func appearance(_ name: NSAppearance.Name) async {
            NSApp.appearance = NSAppearance(named: name)
            let pane = model.workspace.selectedTab(of: plot)?.focused
            try? await app.waitUntil("the pane follows \(name.rawValue)", timeout: 10) {
                guard let view = pane.flatMap({ host.paneView($0) as? TerminalSurfaceView }),
                      let pixel = app.backgroundPixel(view) else { return false }
                return (pixel.0 + pixel.1 + pixel.2 < 3 * 128) == (name == .darkAqua)
            }
            await app.sleep(1)
        }
        await appearance(.darkAqua)
        app.screenshot("night")
        await appearance(.aqua)
        app.screenshot("day")

        // Clicks cycle through the panes in a state, across plots.
        await appearance(.darkAqua)
        try app.click("attention-needs-you")
        try await app.waitUntil("the first click reaches the first pane that needs you") { model.workspace.focusedPane == panesTwo[0] }
        try app.click("attention-needs-you")
        try await app.waitUntil("the second click reaches the next pane") { model.workspace.focusedPane == paneThree }
        try app.click("attention-needs-you")
        try await app.waitUntil("the third click wraps round") { model.workspace.focusedPane == panesTwo[0] }
        try app.click("attention-done-unread")
        try await app.waitUntil("Done, unread goes to its pane") { model.workspace.focusedPane == panesTwo[1] }

        // The search button opens the switcher.
        try app.click("sidebar-search")
        try await app.waitUntil("the switcher shows", timeout: 5) { app.exists("switcher-field") }
        model.switcher.close()
        try await app.waitUntil("the switcher closes", timeout: 5) { !app.exists("switcher-field") }
        model.activate(number: 1)

        // A third-party theme.
        try app.writeConfig(config + "\nbackground = #1e1e2e\nforeground = #cdd6f4\n")
        app.runtime.reloadConfig()
        try await app.waitUntil("the chrome follows Catppuccin Mocha", timeout: 10) {
            ChromePalette.shared.current?.bedrock == 0x1e1e2e
        }
        await app.sleep(1.2)
        app.screenshot("catppuccin")
        // Translucent.
        try app.writeConfig(config + "\nbackground = #1e1e2e\nforeground = #cdd6f4\nbackground-opacity = 0.8\nbackground-blur = 20\n")
        app.runtime.reloadConfig()
        try await app.waitUntil("the window turns translucent", timeout: 10) { ChromePalette.shared.isTranslucent }
        await app.sleep(1.2)
        app.screenshot("translucent")
        NSApp.appearance = nil
    }
}
