import AppKit
import LoamKit
import LoamTerminal

/// Driver scenarios for ticket 100: a Home tab moves to a plot. The two scenarios are two app runs
/// on the Home rig (`HomeRig`).
@MainActor
extension Scenarios {
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    /// What the first run leaves for the second.
    private struct MoveSaved: Codable {
        var plot: String
        var tree: SplitTree
        var session: PaneID
        var sessionID: String
    }

    private static var moveSavedName: String { "move-expect.json" }

    private static func button(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(title, in: $0) }.first
    }

    private static func textField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }

    /// Runs one row of the ⌘J menu. `query` must leave `row` as the first row.
    private static func runAction(_ app: DriverApp, query: String, row: String) async throws {
        app.press(letter: "j", flags: .command)
        try await app.waitUntil("the menu opens") { app.exists("actions-menu") }
        try await app.waitUntil("the search field has the keys") { app.window.firstResponder is NSTextView }
        try app.type(query)
        try await app.waitUntil("the filter leaves \(row)") { app.exists("actions-row-\(row)") }
        app.press(.returnKey)
        try await app.waitUntil("the menu closes") { !app.exists("actions-menu") }
    }

    /// Makes the file where Claude Code keeps the conversation of a session. The core finds it by
    /// the session ID in any project folder.
    private static func conversation(_ sessionID: String, config: URL) throws {
        let dir = config.appendingPathComponent("projects/-home")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("\(sessionID).jsonl"))
    }

    /// The shell's process ID and its `LOAM_PLOT`, from an echo in the shell.
    private static func shellReport(_ app: DriverApp, _ view: TerminalSurfaceView, mark: String) async throws -> String {
        try await app.waitUntil("the shell has the keys") { app.window.firstResponder === view }
        try app.type("echo \"\(mark) pid=$$ plot=${LOAM_PLOT:-none}\"")
        app.press(.returnKey)
        var report: String?
        try await app.waitUntil("the shell output \(mark)") {
            report = app.lines(view).first { $0.hasPrefix("\(mark) pid=") }
            return report != nil
        }
        return String(report!.dropFirst(mark.count + 1))
    }

    /// Run 1: a Home tab of a shell and a session split. After `/clear`, ⌘J "Move to Alpha" moves it:
    /// the shell keeps its view and its process, and the session resumes its new ID in the plot with
    /// `LOAM_PLOT`. Then ⌘J "Move to New Plot…" asks for a name, asks first because a second Home
    /// session is mid-turn, makes the plot Beta, and moves that tab there. That session has no
    /// conversation, so it starts again with its ID.
    static func moveToPlot(_ app: DriverApp) async throws {
        do { try await moveToPlotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func moveToPlotSteps(_ app: DriverApp) async throws {
        // A turn lasts long enough for the question of step 6.
        let setup = try HomeRig(fresh: true, turn: "60s")
        let host = try await setup.launch(app)
        let model = host.model
        let home = URL(fileURLWithPath: model.homeFolder).resolvingSymlinksInPath().path
        try await app.waitUntil("Home is active") { model.workspace.activeSpace == .home }
        let alpha = try setup.rig.newPlot("Alpha")
        await model.reloadPlots()
        try expect(model.plots.map(\.id) == [alpha], "the plot list is \(model.plots.map(\.id))")

        // 1. A Home tab: a shell, then a session split.
        model.openHomeTab(.shell)
        guard let tab = model.workspace.selectedTab(of: .home), let shellView = host.paneView(tab.focused) as? TerminalSurfaceView else {
            throw DriverFailure("the Home shell has no terminal")
        }
        let shell = tab.focused
        let before = try await shellReport(app, shellView, mark: "before")
        try expect(before.hasSuffix(" plot=none"), "the Home shell reports \(before)")
        model.split(.sideBySide, .session)
        let session = try model.workspace.selectedTab(of: .home)?.focused ?? { throw DriverFailure("no session split") }()
        try await app.waitUntil("the session started") { model.workspace.session(of: session)?.started == true }
        let first = model.workspace.session(of: session)!.sessionID!

        // 2. /clear gives the session a new ID. The move must resume that one.
        try await app.waitUntil("the session has the keys") { app.window.firstResponder === host.paneView(session) }
        try app.type("/clear")
        app.press(.returnKey)
        try await app.waitUntil("the session has a new ID") {
            model.workspace.session(of: session)?.sessionID.map { $0 != first } ?? false
        }
        let current = model.workspace.session(of: session)!.sessionID!
        try FileManager.default.removeItem(at: setup.invocationFile)
        // Claude Code keeps the conversation of the session once it has a prompt.
        try conversation(current, config: setup.claudeConfig)

        // 3. ⌘J "Move to Alpha". Alpha becomes active with the moved tab, and Home is empty.
        try await runAction(app, query: "move alpha", row: "Move to Alpha")
        try await app.waitUntil("the tab is in Alpha") {
            model.workspace.activeSpace == .plot(alpha) && model.workspace.selectedTab(of: .plot(alpha))?.id == tab.id
        }
        try expect(model.workspace.tabs(of: .home).isEmpty, "Home still has a tab")
        try expect(model.workspace.tabs(of: .plot(alpha)).map(\.id) == [tab.id], "Alpha has other tabs")

        // 4. The shell is the same view and the same process, with no LOAM_PLOT.
        try expect(host.paneView(shell) === shellView, "the shell got a new view")
        try expect(model.workspace.launch(of: shell) == 0, "the shell restarted")
        model.focus(shell)
        let after = try await shellReport(app, shellView, mark: "after")
        try expect(after == before, "the shell reports \(after), not \(before)")
        Log.line("RESULT shell after the move: \(after)")

        // 5. The session resumes its current ID in Alpha, seeded, in the home folder.
        try await app.waitUntil("the session resumed") { setup.invocation()?.args.contains("--resume") == true }
        let resumed = setup.invocation()!
        Log.line("RESULT claude args after the move: \(resumed.args.joined(separator: " "))")
        try expect(resumed.args.contains(current), "claude did not resume \(current)")
        try expect(resumed.env["LOAM_PLOT"] == alpha, "the resumed session has LOAM_PLOT \(resumed.env["LOAM_PLOT"] ?? "none")")
        try expect(resumed.args.contains("--add-dir"), "the resumed session has no added folder")
        try expect(URL(fileURLWithPath: resumed.cwd).resolvingSymlinksInPath().path == home,
                   "the session runs in \(resumed.cwd), not \(home)")
        try await app.waitUntil("SessionStart reached the moved pane") {
            model.workspace.session(of: session)?.started == true && model.workspace.session(of: session)?.sessionID == current
        }
        app.screenshot("move-to-plot")

        // 6. A second Home session, mid-turn. ⌘J "Move to New Plot…" asks for a name, then asks
        // first, then makes the plot and moves the tab there.
        model.activateHome()
        model.openHomeTab(.session)
        let second = try model.workspace.selectedTab(of: .home) ?? { throw DriverFailure("no second Home tab") }()
        try await app.waitUntil("the second session started") { model.workspace.session(of: second.focused)?.started == true }
        try await app.waitUntil("the second session has the keys") { app.window.firstResponder === host.paneView(second.focused) }
        try app.type("hello")
        app.press(.returnKey)
        try await app.waitUntil("the second session is mid-turn") { model.workspace.state(of: second.focused) == .working }
        let secondID = model.workspace.session(of: second.focused)!.sessionID!
        try FileManager.default.removeItem(at: setup.invocationFile)
        try await runAction(app, query: "new plot", row: "Move to New Plot…")
        try await app.waitUntil("the name sheet") { textField(in: app.window.attachedSheet?.contentView) != nil }
        guard let sheet = app.window.attachedSheet, let field = textField(in: sheet.contentView),
              let create = button("Create", in: sheet.contentView) else { throw DriverFailure("the name sheet has no field or Create") }
        field.stringValue = "Beta"
        create.performClick(nil)
        try await app.waitUntil("the move question") { button("Move", in: app.window.attachedSheet?.contentView) != nil }
        try expect(model.plots.count == 1, "a plot was made before the answer")
        app.screenshot("move-question")
        button("Move", in: app.window.attachedSheet?.contentView)!.performClick(nil)
        try await app.waitUntil("Beta has the tab") {
            guard let beta = model.plots.first(where: { $0.name == "Beta" })?.id else { return false }
            return model.workspace.activeSpace == .plot(beta) && model.workspace.selectedTab(of: .plot(beta))?.id == second.id
        }
        try expect(model.workspace.tabs(of: .home).isEmpty, "Home still has the second tab")
        try await app.waitUntil("the second session started again") {
            setup.invocation()?.args.starts(with: ["--session-id", secondID]) == true
        }
        Log.line("RESULT New Plot… asked first, then moved the tab to Beta, and the session started again with \(secondID)")

        guard let moved = model.workspace.tabs(of: .plot(alpha)).first else { throw DriverFailure("Alpha lost the tab") }
        let saved = MoveSaved(plot: alpha, tree: moved.tree, session: session, sessionID: current)
        try JSONEncoder().encode(saved).write(to: setup.rig.root.appendingPathComponent(moveSavedName))
        try await quitHome(host, app)
    }

    /// Run 2: the moved tab is back in Alpha. The session resumes from its record with a plain
    /// `loam resume`, still with `LOAM_PLOT`.
    static func moveToPlotRelaunch(_ app: DriverApp) async throws {
        do { try await moveToPlotRelaunchSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func moveToPlotRelaunchSteps(_ app: DriverApp) async throws {
        let setup = try HomeRig(fresh: false)
        let saved = try JSONDecoder().decode(MoveSaved.self, from: Data(contentsOf: setup.rig.root.appendingPathComponent(moveSavedName)))
        try FileManager.default.removeItem(at: setup.invocationFile)
        let host = try await setup.launch(app)
        let model = host.model
        try await app.waitUntil("the plots arrive") { model.plots.count == 2 }
        try expect(model.workspace.tabs(of: .plot(saved.plot)).map(\.tree) == [saved.tree], "Alpha has another layout")
        try expect(model.workspace.tabs(of: .home).isEmpty, "Home has tabs again")
        model.activate(plot: saved.plot)
        let command = model.workspace.spec(of: saved.session)?.command ?? ""
        try expect(command.hasSuffix("resume \(saved.sessionID)'"), "the moved pane runs \(command)")
        try await app.waitUntil("the session resumed") {
            model.workspace.session(of: saved.session)?.started == true && setup.invocation() != nil
        }
        try expect(model.workspace.session(of: saved.session)?.sessionID == saved.sessionID, "the pane runs another session")
        try expect(setup.invocation()?.env["LOAM_PLOT"] == saved.plot, "the relaunched session has no LOAM_PLOT")
        Log.line("RESULT the moved session resumed in Alpha after a relaunch")
        app.screenshot("move-to-plot-relaunch")
        try await quitHome(host, app)
    }
}
