import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 96: the `x` on a hovered tab. Hover a tab that is not selected, click
/// its `x`, and the tab goes while the selection stays. Then hover a tab with a session that is
/// mid-turn, click its `x`, and the close question shows. It uses a temp `LOAM_HOME`, a fake HOME,
/// and the core's fake `claude` in hook mode (`LOAM_DRIVER_FAKE_CLAUDE`). It never touches `~/.loam`.
@MainActor
extension Scenarios {
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func tabClose(_ app: DriverApp) async throws {
        do { try await tabCloseSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func tabCloseSteps(_ app: DriverApp) async throws {
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
            "LOAM_FAKE_CLAUDE_TURN": "20s",
        ]) { $1 }

        let plot = try rig.newPlot("Tab close")
        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        let model = host.model
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }
        func tabs() -> [Tab] { model.workspace.tabs(of: plot) }
        func selected() -> UUID? { model.workspace.selectedTab(of: plot)?.id }

        func bar(in view: NSView) -> (any FirstTabFraming)? {
            (view as? any FirstTabFraming) ?? view.subviews.lazy.compactMap(bar).first
        }
        func closeButton(in view: NSView) -> NSView? {
            if view.accessibilityIdentifier().hasPrefix("tab-close-"), !view.isHidden { return view }
            return view.subviews.lazy.compactMap(closeButton).first
        }
        guard let content = app.window.contentView, let tabBar = bar(in: content) else { throw DriverFailure("no tab bar") }
        func hover(_ index: Int) throws {
            guard let frame = tabBar.tabFrame(at: index) else { throw DriverFailure("no tab \(index + 1)") }
            app.mouse(.mouseMoved, at: tabBar.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil))
        }
        /// Hovers the tab, waits for its `x`, and clicks it.
        func clickClose(_ index: Int) async throws {
            try hover(index)
            try await app.waitUntil("the x of tab \(index + 1)") {
                content.layoutSubtreeIfNeeded()
                return closeButton(in: tabBar)?.accessibilityIdentifier() == "tab-close-\(index + 1)"
            }
            guard let button = closeButton(in: tabBar) else { throw DriverFailure("no x") }
            await app.sleep(0.2)
            app.screenshot("hover-x-\(index + 1)")
            try expect(button.accessibilityLabel() == "Close tab", "the x says \(button.accessibilityLabel() ?? "nothing")")
            try expect(abs(button.frame.width - 16) < 0.01 && abs(button.frame.height - 16) < 0.01, "the x is \(button.frame.size)")
            app.mouse(.leftMouseDown, at: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
            app.mouse(.leftMouseUp, at: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
        }

        // Three tabs: two shells, then a session. The session tab is selected.
        await model.openShellTab()
        await model.openShellTab()
        try app.pressMenuKey("t")
        try await app.waitUntil("three tabs") { tabs().count == 3 }
        let shellOne = tabs()[0].id, shellTwo = tabs()[1].id, session = tabs()[2].id
        try expect(selected() == session, "the session tab is not selected")
        let sessionPane = tabs()[2].focused
        try await app.waitUntil("the session started") { model.workspace.session(of: sessionPane)?.started == true }
        app.screenshot("tabs")

        // Nothing is hovered, so no tab has an `x`.
        try expect(closeButton(in: tabBar) == nil, "an x shows with no hover")

        // 1. Hover tab 1 (not selected) and click its `x`. The tab goes. The selection stays.
        try await clickClose(0)
        try await app.waitUntil("tab 1 is gone") { tabs().count == 2 }
        try expect(tabs().map(\.id) == [shellTwo, session], "the wrong tab closed: \(tabs().map(\.id))")
        try expect(selected() == session, "the selection moved")
        try expect(app.window.attachedSheet == nil, "a shell tab asked before it closed")
        _ = shellOne
        Log.line("RESULT closed tab 1 from its x, selection stayed on the session tab")

        // 2. A prompt makes the session mid-turn. Select the shell tab, hover the session tab, click its `x`.
        try await app.waitUntil("the terminal has the keys") { app.window.firstResponder is TerminalSurfaceView }
        try app.type("hello")
        app.press(.returnKey)
        try await app.waitUntil("working") { model.workspace.state(of: sessionPane) == .working }
        model.selectTab(index: 0)
        try await app.waitUntil("the shell tab is selected") { selected() == shellTwo }
        try await clickClose(1)
        try await app.waitUntil("the close question") { app.window.attachedSheet != nil }
        try expect(tabs().count == 2, "the tab closed before the answer")
        try expect(selected() == shellTwo, "the click on the x selected the tab")
        app.screenshot("close-question")
        guard let sheet = app.window.attachedSheet, let cancel = button("Cancel", in: sheet.contentView) else {
            throw DriverFailure("the close question has no Cancel button")
        }
        cancel.performClick(nil)
        try await app.waitUntil("the question is gone") { app.window.attachedSheet == nil }
        try expect(tabs().map(\.id) == [shellTwo, session], "Cancel closed a tab")

        // 3. Ask again and confirm: the session tab closes, and the selection stays.
        try await clickClose(1)
        try await app.waitUntil("the close question again") { app.window.attachedSheet != nil }
        guard let again = app.window.attachedSheet, let confirm = button("Close", in: again.contentView) else {
            throw DriverFailure("the close question has no Close button")
        }
        confirm.performClick(nil)
        try await app.waitUntil("the session tab is gone", timeout: 15) { tabs().map(\.id) == [shellTwo] }
        try expect(selected() == shellTwo, "the selection moved after the confirmed close")
        Log.line("RESULT the mid-turn tab asked first, Cancel kept it, Close closed it")
    }

    private static func button(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(title, in: $0) }.first
    }
}
