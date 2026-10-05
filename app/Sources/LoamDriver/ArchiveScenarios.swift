import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 48: archive a plot with a session, unarchive it, see the session
/// resume, and delete another archived plot. Ticket 61: archive again, then unarchive and show the
/// plot at once, and see only one `claude` for the session. It uses a temp `LOAM_HOME`, a temp
/// state folder, a fake HOME (so the Trash is a temp folder), and the core's fake `claude` in hook
/// mode (`LOAM_DRIVER_FAKE_CLAUDE`). It never touches `~/.loam`.
@MainActor
extension Scenarios {
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func archive(_ app: DriverApp) async throws {
        do { try await archiveSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func archiveSteps(_ app: DriverApp) async throws {
        let rig = try PanelRig(outFolder: app.outFolder)
        guard let fake = ProcessInfo.processInfo.environment["LOAM_DRIVER_FAKE_CLAUDE"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_CLAUDE does not name the fake claude")
        }
        let fm = FileManager.default
        let bin = rig.root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.copyItem(atPath: fake, toPath: bin.appendingPathComponent("claude").path)
        try "".write(to: rig.fakeHome.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let environment = rig.environment.merging([
            "PATH": bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
            "LOAM_FAKE_CLAUDE_OUT": rig.root.appendingPathComponent("claude-invocation.json").path,
            "LOAM_FAKE_CLAUDE_HOOKS": "1",
            "LOAM_FAKE_CLAUDE_TURN": "3s",
            // After a SIGHUP the fake claude keeps running, as Claude Code can while it ends a session.
            // The safe close kills it after 2 s, so an old claude lives 2 s after each archive.
            "LOAM_FAKE_CLAUDE_HUP_WAIT": "10s",
        ]) { $1 }

        let keep = try rig.newPlot("Keep plot")
        let finished = try rig.newPlot("Finished plot")
        let mistake = try rig.newPlot("Mistake plot")
        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        let model = host.model
        try await app.waitUntil("the first plot is active") { model.workspace.activePlotID == keep }
        func surface(_ pane: PaneID) throws -> TerminalSurfaceView {
            guard let view = host.paneView(pane) as? TerminalSurfaceView else { throw DriverFailure("pane \(pane) has no terminal") }
            return view
        }

        // 1. A session in the plot that will be archived, and a shell split.
        model.activate(plot: finished)
        try app.pressMenuKey("t")
        try await app.waitUntil("a seeded pane") { model.workspace.selectedTab(of: finished) != nil }
        let session = model.workspace.selectedTab(of: finished)!.focused
        try await app.waitUntil("the session started") { model.workspace.session(of: session)?.started == true }
        let sessionID = model.workspace.session(of: session)?.sessionID ?? ""
        await model.splitShell(.sideBySide)
        try await app.waitUntil("a shell split") { model.workspace.paneCount(of: finished) == 2 }
        let shell = model.workspace.selectedTab(of: finished)!.focused
        try await app.waitUntil("idle") { model.workspace.state(of: session) == .idle }
        try expect(model.archivePrompt(for: finished) == nil, "archive asks while the session is idle")

        // 2. A turn makes the session working, so archive asks.
        model.focus(session)
        try await app.waitUntil("the session has the keys") { app.window.firstResponder === (try? surface(session)) }
        try app.type("hello")
        app.press(.returnKey)
        try await app.waitUntil("working") { model.workspace.state(of: session) == .working }
        let tabs = model.workspace.tabs(of: finished)
        try expect(model.archivePrompt(for: finished)?.confirm == "Archive", "archive does not ask while the session works")
        app.screenshot("archive-working")

        // 3. Archive: the sessions end, the layout stays, and the plot leaves the sidebar.
        try expect(await model.archivePlot(finished), "archive failed: \(model.lastError ?? "no error")")
        try expect(host.paneView(session) == nil && host.paneView(shell) == nil, "a pane still has a view after archive")
        try expect(model.workspace.tabs(of: finished) == tabs, "archive changed the layout")
        try expect(model.archivedPlots.map(\.id) == [finished], "the archived list is \(model.archivedPlots.map(\.id))")
        try expect(!model.plots.contains { $0.id == finished }, "the plot is still in the plot list")
        try expect(model.workspace.activePlotID != finished, "the archived plot is still active")
        try await app.waitUntil("the sidebar row is gone") { !app.exists("plot-\(finished)") }
        try await app.waitUntil("the Archived header") { app.exists("archived-header") }
        let list = try rig.loam(["list", "--archived", "--json"])
        try expect(list.contains(finished), "loam list --archived does not list the plot")
        // The core refuses to start or resume while the plot is archived.
        try expect((try? rig.loam(["resume", sessionID])) == nil, "loam resume ran for an archived plot")
        try await app.waitUntil("state.json keeps the panes") {
            Set(SavedLayout.read(from: rig.stateFile).panes.map(\.id)).isSuperset(of: [session, shell])
        }
        app.screenshot("archived")

        // 4. Unarchive: the plot returns to its old place. Its session resumes when it shows.
        try expect(await model.unarchivePlot(finished), "unarchive failed: \(model.lastError ?? "no error")")
        try expect(model.plots.map(\.id) == [keep, finished, mistake], "the order is \(model.plots.map(\.id))")
        try expect(model.workspace.isWaiting(finished) && host.paneView(session) == nil, "the panes started before the plot showed")
        model.activate(plot: finished)
        try await app.waitUntil("the session resumed") { model.workspace.session(of: session)?.started == true }
        try expect(model.workspace.session(of: session)?.sessionID == sessionID, "the session ID changed")
        let view = try surface(session)
        try await app.waitUntil("the resumed session text") { view.screenText().contains("fake claude: session \(sessionID)") }
        try expect(host.paneView(shell) is TerminalSurfaceView, "the shell pane has no terminal")
        app.screenshot("unarchived")

        // 5. Archive, then unarchive and show the plot at once, while the old claude still ends.
        // The resume waits for the safe close, so two processes never hold the session (ticket 61).
        try await app.waitUntil("one claude runs the session") { claudeCount(sessionID) == 1 }
        try expect(await model.archivePlot(finished), "archive failed: \(model.lastError ?? "no error")")
        try expect(await model.unarchivePlot(finished), "unarchive failed: \(model.lastError ?? "no error")")
        model.activate(plot: finished)
        try expect(claudeCount(sessionID) == 1, "the old claude ended before the plot showed, so this checks nothing")
        try expect(host.paneView(session) == nil, "the session resumed while the old claude still ends")
        var most = 0
        try await app.waitUntil("the session resumed again") {
            most = max(most, claudeCount(sessionID))
            return (try? surface(session))?.screenText().contains("fake claude: session \(sessionID)") == true
        }
        try expect(most == 1, "\(most) claude processes held the session at one time")
        try expect(claudeCount(sessionID) == 1, "\(claudeCount(sessionID)) claude processes hold the session")
        try expect(host.paneView(shell) is TerminalSurfaceView, "the shell pane has no terminal")

        // 6. Delete an archived plot: the plot, its folder, and its panes go.
        model.activate(plot: mistake)
        try app.pressMenuKey("t")
        try await app.waitUntil("a pane in the plot to delete") { model.workspace.paneCount(of: mistake) == 1 }
        try expect(await model.deletePlot(mistake) == nil, "delete ran for a plot that is not archived")
        try expect(await model.archivePlot(mistake), "archive failed: \(model.lastError ?? "no error")")
        let folder = model.plotFolder(mistake)
        guard let result = await model.deletePlot(mistake) else {
            throw DriverFailure("delete failed: \(model.lastError ?? "no error")")
        }
        Log.line("RESULT delete: trash \(result.trash), claude files \(result.claudeFiles)")
        try expect(result.plot == mistake && result.name == "Mistake plot", "the result names \(result.plot)")
        try expect(result.trash.hasPrefix(rig.fakeHome.path + "/.Trash/"), "the trash path is \(result.trash)")
        try expect(fm.fileExists(atPath: result.trash) && !fm.fileExists(atPath: folder), "the plot folder is not in the Trash")
        try expect(model.archivedPlots.isEmpty, "the archived list still has \(model.archivedPlots.map(\.id))")
        try expect(model.workspace.tabs(of: mistake).isEmpty, "the deleted plot still has tabs")
        try await app.waitUntil("state.json drops the panes") {
            !SavedLayout.read(from: rig.stateFile).panes.contains { $0.plotID == mistake }
        }
        try await app.waitUntil("the Archived header is gone") { !app.exists("archived-header") }
        let after = try rig.loam(["list", "--json"])
        try expect(!after.contains(mistake) && after.contains(finished), "the plot list is wrong after delete")
        let exported = try rig.loam(["export"])
        try expect(!exported.contains(mistake), "loam export still holds the deleted plot")
    }

    /// The number of `claude` processes for the session: the argv starts with `claude` and names
    /// the ID. `loam start` and `loam resume` exec `claude`, so a pane's process has this argv.
    private static func claudeCount(_ sessionID: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "args="]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("claude ") && $0.contains(sessionID) }.count
    }
}
