import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 28: seeded and shell panes in the real window, the pane socket,
/// and "Session ended". The seeded panes run the real `loam start` and `loam resume` against a
/// temp store. `claude` is the core's fake (`core/internal/testutil/fakeclaude`) in hook mode:
/// it runs the hooks of the settings file, so each hook goes through `loam hook` to the pane
/// socket. `LOAM_DRIVER_FAKE_CLAUDE` names the fake binary.
@MainActor
extension Scenarios {
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func panes(_ app: DriverApp) async throws {
        do { try await paneSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// What the fake claude recorded about its last run.
    private struct Invocation: Decodable {
        var args: [String]
        var env: [String: String]
    }

    private static func paneSteps(_ app: DriverApp) async throws {
        let rig = try PanelRig(outFolder: app.outFolder)
        guard let fake = ProcessInfo.processInfo.environment["LOAM_DRIVER_FAKE_CLAUDE"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_CLAUDE does not name the fake claude")
        }
        let fm = FileManager.default
        let bin = rig.root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.copyItem(atPath: fake, toPath: bin.appendingPathComponent("claude").path)
        // No zsh "new user" prompt in a shell pane with the fake HOME.
        try "".write(to: rig.fakeHome.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let invocationFile = rig.root.appendingPathComponent("claude-invocation.json")
        func invocation() -> Invocation? {
            (try? Data(contentsOf: invocationFile)).flatMap { try? JSONDecoder().decode(Invocation.self, from: $0) }
        }
        // The client's environment is the pane's environment, so the fake comes first on PATH.
        let environment = rig.environment.merging([
            "PATH": bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
            "LOAM_FAKE_CLAUDE_OUT": invocationFile.path,
            "LOAM_FAKE_CLAUDE_HOOKS": "1",
            "LOAM_FAKE_CLAUDE_TURN": "1s",
        ]) { $1 }
        let plot = try rig.newPlot("Pane plot")
        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        let model = host.model
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }
        func focused() -> PaneID? { model.workspace.selectedTab(of: .plot(plot))?.focused }
        func surface(_ pane: PaneID) throws -> TerminalSurfaceView {
            guard let view = host.paneView(pane) as? TerminalSurfaceView else { throw DriverFailure("pane \(pane) has no terminal") }
            return view
        }
        func session(_ pane: PaneID) -> PaneSession? { model.workspace.session(of: pane) }

        // 1. ⌘T starts a seeded session: `loam start --session-id` in a login shell, with the pane socket.
        try app.pressMenuKey("t")
        try await app.waitUntil("a seeded pane") { focused() != nil }
        let seeded = focused()!
        let first = try model.workspace.spec(of: seeded)?.sessionID ?? { throw DriverFailure("no session ID") }()
        try check(model.workspace.spec(of: seeded)?.kind == .session, "⌘T did not open a seeded pane")
        try await app.waitUntil("the fake claude ran") { invocation()?.args.contains(first) == true }
        let start = invocation()!
        Log.line("RESULT claude args: \(start.args.joined(separator: " "))")
        try check(start.args.starts(with: ["--session-id", first]), "claude did not get --session-id \(first)")
        let socket = start.env["LOAM_PANE_SOCKET"] ?? ""
        try check(!socket.isEmpty && fm.fileExists(atPath: socket), "the session has no pane socket: \(socket)")
        try check(start.env["LOAM_PLOT"] == plot, "the session has no LOAM_PLOT")
        try await app.waitUntil("SessionStart reached the pane") { session(seeded)?.started == true }
        try check(session(seeded)?.sessionID == first && model.workspace.state(of: seeded) == .idle, "the pane is not idle on \(first)")
        let seededView = try surface(seeded)
        try await app.waitUntil("the session text") { seededView.screenText().contains("fake claude: session \(first)") }

        // 2. A prompt makes the pane working, and Stop makes it idle.
        try app.type("hello")
        app.press(.returnKey)
        try await app.waitUntil("working") { model.workspace.state(of: seeded) == .working }
        try await app.waitUntil("idle after Stop") { model.workspace.state(of: seeded) == .idle }

        // 3. /clear gives a new session ID. The review still finds the pane for both IDs.
        try app.type("/clear")
        app.press(.returnKey)
        try await app.waitUntil("a new session ID") { session(seeded)?.sessionID.map { $0 != first } == true }
        let second = session(seeded)!.sessionID!
        try check(model.workspace.state(of: seeded) == .idle, "the pane is not idle after /clear")
        try check(model.review.paneLookup?(second)?.id == seeded && model.review.paneLookup?(first)?.id == seeded,
                  "the review does not find the pane")
        Log.line("RESULT session IDs: \(first) then \(second)")

        // 4. ⌘⌥T opens a shell tab in the plot's start folder, with its own socket.
        try app.pressMenuKey("t", flags: [.command, .option])
        try await app.waitUntil("a shell tab") { model.workspace.tabs(of: .plot(plot)).count == 2 }
        let shell = focused()!
        let shellSpec = model.workspace.spec(of: shell)
        try check(shellSpec?.kind == .shell && shellSpec?.command == nil, "⌘⌥T did not open a shell")
        try check(shellSpec?.folder == model.plotFolder(plot), "the shell folder is \(shellSpec?.folder ?? "none")")
        let shellView = try surface(shell)
        try app.type("echo \"cwd=$(pwd) socket=${LOAM_PANE_SOCKET:+set}\"")
        app.press(.returnKey)
        try await app.waitUntil("the shell output") {
            app.lines(shellView).contains { $0.hasPrefix("cwd=") && $0.hasSuffix("/plots/\(plot) socket=set") }
        }
        try check(model.workspace.state(of: shell) == .running, "the shell pane is not running")
        app.screenshot("shell")

        // 5. /exit ends the session. The pane stays and shows "Session ended", which takes the keys.
        model.selectTab(number: 1)
        try await app.waitUntil("the seeded pane has focus") { app.window.firstResponder === seededView }
        try app.type("/exit")
        app.press(.returnKey)
        try await app.waitUntil("the process exited") { session(seeded)?.exited == true }
        try await app.waitUntil("the Session ended bar") { app.exists("pane-ended-\(seeded.uuidString)") }
        try check(model.workspace.state(of: seeded) == .ended, "the pane state is not ended")
        try check(!(app.window.firstResponder is TerminalSurfaceView), "the ended terminal still takes the keys")
        try check(!seededView.screenText().contains("Press any key"), "libghostty's exit message shows")
        // Esc from the switcher gives the keys back to the Session ended bar, not to the ended terminal.
        try app.pressMenuKey("p", flags: .command)
        try await app.waitUntil("the switcher shows") { app.exists("switcher-field") }
        app.press(.escape)
        try await app.waitUntil("the switcher closes") { !app.exists("switcher-field") }
        try check(!(app.window.firstResponder is TerminalSurfaceView), "the ended terminal took the keys back from the switcher")
        try app.type("x")  // A stray key changes nothing.
        await app.sleep(0.3)
        try check(model.workspace.spec(of: seeded) != nil, "a stray key closed the pane")
        // The bar sits under the terminal, which gives it room.
        let bar = seededView.superview?.subviews.first { $0.accessibilityIdentifier() == "pane-ended-\(seeded.uuidString)" }
        try check((bar?.frame.height ?? 0) > 0 && bar.map { seededView.frame.minY >= $0.frame.maxY } == true,
                  "the bar has no room: bar \(bar?.frame ?? .zero), terminal \(seededView.frame)")
        app.screenshot("session-ended")

        // 6. Return resumes the last session ID in the same pane: same ID and place, a new terminal.
        app.press(.returnKey)
        try await app.waitUntil("the pane restarted") { model.workspace.launch(of: seeded) == 1 }
        try check(focused() == seeded && model.workspace.selectedTab(of: .plot(plot))?.tree == .leaf(seeded),
                  "the resumed pane is not in the old place")
        try await app.waitUntil("the fake claude resumed") { invocation()?.args.starts(with: ["--resume", second]) == true }
        try await app.waitUntil("SessionStart of the resume") { session(seeded)?.started == true }
        try check(session(seeded)?.sessionID == second, "the resumed pane runs \(session(seeded)?.sessionID ?? "none")")
        try check(!app.exists("pane-ended-\(seeded.uuidString)"), "the Session ended bar still shows")
        let resumedView = try surface(seeded)
        try check(resumedView !== seededView, "the resumed pane has the old terminal")
        try await app.waitUntil("the new terminal has the keys") { app.window.firstResponder === resumedView }

        // 7. /exit, then N starts a new session with a new ID.
        try app.type("/exit")
        app.press(.returnKey)
        try await app.waitUntil("the resumed session ended") { app.exists("pane-ended-\(seeded.uuidString)") }
        try app.type("n")
        try await app.waitUntil("the pane restarted again") { model.workspace.launch(of: seeded) == 2 }
        try await app.waitUntil("SessionStart of the new session") { session(seeded)?.started == true }
        let third = session(seeded)!.sessionID!
        try check(third != first && third != second, "N did not start a new session ID")
        try check(invocation()?.args.starts(with: ["--session-id", third]) == true, "claude did not get the new ID")
        try check(model.review.paneLookup?(first)?.id == seeded, "the review lost the pane of the first session")

        // 7b. Hiding the plot panel gives the keys back to the pane. You type in Where it stands, and ⌘I hides
        // the panel: the keys must not stay in the hidden field.
        try await app.waitUntil("the new terminal has the keys") { app.window.firstResponder is TerminalSurfaceView }
        try app.pressMenuKey("i")
        try await app.waitUntil("the panel shows") { app.exists("panel-whereItStands") }
        try app.fill("panel-whereItStands", with: "dra")
        try check(AccessibilityProbe.shared.isFocused("panel-whereItStands"), "the field has no focus")
        try app.pressMenuKey("i")
        try await app.waitUntil("the panel hides") { !model.panel.visible }
        try check(app.window.firstResponder === (try surface(seeded)), "the keys stayed in the hidden panel")
        await app.sleep(0.5)  // The hidden panel must not take them back.
        try check(app.window.firstResponder === (try surface(seeded)), "the hidden panel took the keys back")

        // 7c. A session ends while you type in the panel: the field keeps the keys. The Session ended bar
        // would read "n" as New session and Return as Resume. Hiding the panel then gives the keys to the bar.
        try app.pressMenuKey("i")
        try await app.waitUntil("the panel shows again") { model.panel.visible && app.exists("panel-whereItStands") }
        try app.fill("panel-whereItStands", with: "dra")
        try check(AccessibilityProbe.shared.isFocused("panel-whereItStands"), "the field has no focus again")
        let beforeEnd = model.workspace.launch(of: seeded)
        // The text goes to the terminal of the pane, not to the first responder.
        try check(try surface(seeded).perform(action: "text:/exit\\x0d"), "the terminal took no text")
        try await app.waitUntil("the session ended") { app.exists("pane-ended-\(seeded.uuidString)") }
        await app.sleep(0.5)
        try check(AccessibilityProbe.shared.isFocused("panel-whereItStands"), "the Session ended bar took the keys from the field")
        try app.type("n")
        app.press(.returnKey)
        await app.sleep(0.5)
        try check(model.workspace.launch(of: seeded) == beforeEnd && session(seeded)?.exited == true, "a key in the field started a session")
        try check(app.text(of: "panel-whereItStands")?.hasPrefix("dran") == true,
                  "the keys did not go into the field: \(app.text(of: "panel-whereItStands") ?? "nothing")")
        try app.click("panel-revert-whereItStands")
        try await app.waitUntil("Revert drops the draft") { !app.exists("panel-revert-whereItStands") }
        try app.pressMenuKey("i")
        try await app.waitUntil("the panel hides again") { !model.panel.visible }
        let endedBar = try surface(seeded).superview?.subviews.first { $0.accessibilityIdentifier() == "pane-ended-\(seeded.uuidString)" }
        try check(endedBar != nil && app.window.firstResponder === endedBar, "the bar has no keys after the panel hid")
        app.press(.returnKey)  // The bar has the keys, so Return resumes.
        try await app.waitUntil("the pane resumed") { model.workspace.launch(of: seeded) == beforeEnd + 1 }
        try await app.waitUntil("SessionStart of the resume") { session(seeded)?.started == true }
        try await app.waitUntil("the resumed terminal has the keys") { app.window.firstResponder === (try? surface(seeded)) }

        // 7d. Closing an editor of the panel gives the keys back to the pane: Escape in Add link and in Add
        // repo, and Return in Add link.
        // SwiftUI clears the focus of a closed field a moment later, so the keys come back to the pane and stay.
        func keysReturn(_ what: String) async throws {
            try await app.waitUntil("\(what) gives the keys to the pane") { app.window.firstResponder === (try? surface(seeded)) }
            await app.sleep(0.3)
            try check(app.window.firstResponder === (try surface(seeded)), "the keys left the pane after \(what)")
        }
        try app.pressMenuKey("i")
        try await app.waitUntil("the panel shows for the editors") { model.panel.visible && app.exists("panel-add-link-open") }
        for (name, open, field) in [("Add link", "panel-add-link-open", "panel-new-link-target"),
                                    ("Add repo", "panel-add-repo-open", "panel-new-repo")] {
            try app.click(open)
            try await app.waitUntil("\(name) has the focus") { AccessibilityProbe.shared.isFocused(field) }
            app.press(.escape)
            try await app.waitUntil("Escape closes \(name)") { !app.exists(field) }
            try await keysReturn("Escape in \(name)")
        }
        try app.click("panel-add-link-open")
        try await app.waitUntil("Add link has the focus again") { AccessibilityProbe.shared.isFocused("panel-new-link-target") }
        try app.fill("panel-new-link-target", with: "https://example.com/keys")
        app.press(.returnKey)
        try await app.waitUntil("Return closes Add link") { !app.exists("panel-new-link-target") }
        try await keysReturn("Return in Add link")
        try app.pressMenuKey("i")
        try await app.waitUntil("the panel hides for the last time") { !model.panel.visible }

        // 8. /exit, then ⌘W closes the ended pane. The shell tab stays.
        try await app.waitUntil("the new terminal has the keys") { app.window.firstResponder is TerminalSurfaceView }
        try app.type("/exit")
        app.press(.returnKey)
        try await app.waitUntil("the new session ended") { app.exists("pane-ended-\(seeded.uuidString)") }
        try app.pressMenuKey("w")
        try await app.waitUntil("one tab left") { model.workspace.tabs(of: .plot(plot)).count == 1 }
        try check(model.workspace.paneIDs(of: .plot(plot)) == [shell], "the shell pane is gone")
        await app.sleep(0.5)  // The safe close runs, then the socket goes.
        try check(!fm.fileExists(atPath: socket), "the first pane's socket is still there")
    }
}
