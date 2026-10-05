import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 32 (phase 4): the attention states in the real window. Three plots
/// each run a seeded session. A permission prompt in a plot that is not active shows on its sidebar
/// row, ⌘L reaches it, and a key in the pane clears it. It also checks done, unread (and its
/// `state.json` flag), the banner while another app is frontmost (a recording notifier, so no real
/// banner or permission prompt), the title bar button, and that Reduce Motion stops the halo.
///
/// The sessions are the core's fake `claude` in hook mode (`LOAM_DRIVER_FAKE_CLAUDE`): the lines
/// `/permission`, `/question`, and `/fail` raise the needs-you hooks. Temp `LOAM_HOME`, temp state
/// folder, and fake HOME only.
@MainActor
extension Scenarios {
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func attention(_ app: DriverApp) async throws {
        defer { LoamMotion.reduceMotionOverride = nil }
        do { try await attentionSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// Every attention dot in the window, in the sidebar, the badges, and the tab bar.
    private static func dots(in view: NSView?) -> [AttentionDotView] {
        guard let view else { return [] }
        return (view as? AttentionDotView).map { [$0] } ?? view.subviews.flatMap { dots(in: $0) }
    }

    /// True when the title bar button is on screen: it is in the title bar, and no ancestor hides it.
    private static func needsYouButtonShows(_ app: DriverApp) -> Bool {
        func find(_ view: NSView) -> NSView? {
            view.accessibilityIdentifier() == "needs-you-button" ? view : view.subviews.lazy.compactMap(find).first
        }
        guard let frame = app.window.contentView?.superview, let button = find(frame) else { return false }
        return !button.isHiddenOrHasHiddenAncestor && button.visibleRect.width > 0
    }

    private static func attentionSteps(_ app: DriverApp) async throws {
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
            "LOAM_FAKE_CLAUDE_TURN": "2s",
        ]) { $1 }

        let one = try rig.newPlot("One plot")
        let two = try rig.newPlot("Two plot")
        let three = try rig.newPlot("Three plot")
        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        let model = host.model
        // The run must not depend on which app you use while it runs.
        var frontmost = true
        model.isFrontmost = { frontmost }
        let notifier = RecordingNotifier()
        model.notifier = notifier
        LoamMotion.reduceMotionOverride = false
        try await app.waitUntil("three plots") { model.plots.count == 3 }

        func surface(_ pane: PaneID) throws -> TerminalSurfaceView {
            guard let view = host.paneView(pane) as? TerminalSurfaceView else { throw DriverFailure("pane \(pane) has no terminal") }
            return view
        }
        func state(_ pane: PaneID) -> PaneState? { model.workspace.state(of: pane) }
        /// Shows the plot and waits until its pane has the keys.
        func show(_ plot: String, _ pane: PaneID) async throws {
            model.activate(plot: plot)
            try await app.waitUntil("the pane of \(plot) has the keys") { app.window.firstResponder === (try? surface(pane)) }
        }

        // 1. A seeded session in each plot.
        var panes: [String: PaneID] = [:]
        for plot in [one, two, three] {
            model.activate(plot: plot)
            try app.pressMenuKey("t")
            try await app.waitUntil("a seeded pane in \(plot)") { model.workspace.selectedTab(of: plot) != nil }
            let pane = model.workspace.selectedTab(of: plot)!.focused
            try await app.waitUntil("the session in \(plot) started") { model.workspace.session(of: pane)?.started == true }
            try await app.waitUntil("the session text") { (try? surface(pane))?.screenText().contains("fake claude: session") == true }
            panes[plot] = pane
        }
        let paneOne = panes[one]!, paneTwo = panes[two]!, paneThree = panes[three]!

        // 2. A permission prompt in plot two while plot three is active.
        try await show(two, paneTwo)
        try app.type("/permission")
        app.press(.returnKey)
        try await show(three, paneThree)
        try await app.waitUntil("plot two needs you", timeout: 10) { state(paneTwo) == .needsYou }
        try expect(model.workspace.activePlotID == three, "the active plot changed")
        try await app.waitUntil("the sidebar row shows the badge") { app.text(of: "plot-\(two)")?.contains("Needs you: 1") == true }
        try await app.waitUntil("the Needs you row counts it") { app.text(of: "attention-needs-you")?.contains("Needs you: 1") == true }
        try expect(app.text(of: "plot-\(three)")?.contains("Needs you") != true, "the active plot shows a badge")
        try expect(notifier.badge == 1, "the Dock badge is \(notifier.badge)")
        try expect(notifier.banners.isEmpty, "a banner showed while Loam is frontmost")
        try expect(!needsYouButtonShows(app), "the title bar button shows while the sidebar shows")
        try await app.waitUntil("the halo plays on arrival", timeout: 3) {
            dots(in: app.window.contentView).contains { $0.mark == .needs && $0.isHaloRunning }
        }
        Log.line("RESULT plot row: \(app.text(of: "plot-\(two)") ?? "none")")
        app.screenshot("needs-you-on-the-sidebar")

        // 3. ⌘L, through the real key path in the focused terminal, reaches the pane.
        app.press(letter: "l", flags: .command)
        try await app.waitUntil("⌘L reached the pane") {
            model.workspace.activePlotID == two && model.workspace.focusedPane == paneTwo
                && app.window.firstResponder === (try? surface(paneTwo))
        }
        // Ticket 71: the tab holds one pane, so it has no header. The tab dot and the ring carry the state.
        try await app.waitUntil("the tab dot says Needs you") { app.text(of: "tab-mark-1") == "needsYou" }
        try await app.waitUntil("the amber ring") { app.text(of: "pane-ring-\(paneTwo.uuidString)") == "needsYou" }
        try await app.waitUntil("the halo stops while the pane has focus", timeout: 3) {
            !dots(in: app.window.contentView).contains { $0.isHaloRunning }
        }
        try expect(state(paneTwo) == .needsYou, "a glance cleared needs you")
        app.screenshot("needs-you-pane")
        // Tab only moves between the options of a prompt, so it is not typing. The fake claude trims it.
        app.press(.tab)
        try expect(state(paneTwo) == .needsYou, "Tab cleared needs you")

        // 4. A key in the pane clears needs you at once. The allowed tool then ends the turn.
        try app.type("y")
        try expect(state(paneTwo) == .working, "a key did not clear needs you: \(String(describing: state(paneTwo)))")
        app.press(.returnKey)
        try await app.waitUntil("the turn ended") { state(paneTwo) == .idle }
        try expect(model.workspace.attention(of: paneTwo) == .none, "a turn you watched is unread")
        try expect(notifier.removed.contains(paneTwo) && notifier.badge == 0, "the banner or the badge stayed")
        try await app.waitUntil("the Needs you count goes") { app.text(of: "attention-needs-you") == "Needs you" }
        try await app.waitUntil("the ring goes") { app.text(of: "pane-ring-\(paneTwo.uuidString)") == "none" }

        // 5. A turn that ends in a plot that you do not see is done, unread, and state.json keeps it.
        try app.type("hello")
        app.press(.returnKey)
        try await app.waitUntil("working") { state(paneTwo) == .working }
        try await show(one, paneOne)
        try await app.waitUntil("done, unread", timeout: 10) { model.workspace.attention(of: paneTwo) == .doneUnread }
        try await app.waitUntil("the row shows done, unread") { app.text(of: "plot-\(two)")?.contains("Done, unread") == true }
        model.stateWriter?.flush()
        try expect(SavedLayout.read(from: rig.stateFile).panes.first { $0.id == paneTwo }?.doneUnread == true,
                   "state.json does not keep done, unread")
        model.activate(plot: two)
        try expect(model.workspace.attention(of: paneTwo) == .none, "showing the pane did not clear done, unread")
        model.stateWriter?.flush()
        try expect(SavedLayout.read(from: rig.stateFile).panes.first { $0.id == paneTwo }?.doneUnread == false,
                   "state.json still has done, unread")

        // 6. With another app frontmost, a question raises a banner, also in the focused pane.
        try await show(one, paneOne)
        frontmost = false
        try app.type("/question")
        app.press(.returnKey)
        try await app.waitUntil("plot one needs you", timeout: 10) { state(paneOne) == .needsYou }
        try expect(notifier.banners.map(\.pane) == [paneOne], "the banners are \(notifier.banners)")
        try expect(notifier.banners.first?.title == "Needs you in One plot"
                   && notifier.banners.first?.body == "Claude asks you a question.", "the banner is \(notifier.banners)")
        Log.line("RESULT banner: \(notifier.banners[0].title) / \(notifier.banners[0].subtitle) / \(notifier.banners[0].body)")
        frontmost = true
        model.frontmostChanged()
        try app.type("blue")
        app.press(.returnKey)
        try await app.waitUntil("the answer ends the turn") { state(paneOne) == .idle }

        // 7. Reduce Motion: a new needs you shows its dot with no halo.
        LoamMotion.reduceMotionOverride = true
        try await show(three, paneThree)
        try app.type("/fail")
        app.press(.returnKey)
        try await show(one, paneOne)
        try await app.waitUntil("plot three needs you", timeout: 10) { state(paneThree) == .needsYou }
        try await app.waitUntil("the badge on plot three") { app.text(of: "plot-\(three)")?.contains("Needs you: 1") == true }
        await app.sleep(0.3)
        let needsDots = dots(in: app.window.contentView).filter { $0.mark == .needs && !$0.isHidden }
        try expect(!needsDots.isEmpty, "no needs-you dot shows")
        try expect(!needsDots.contains { $0.isHaloRunning }, "the halo runs under Reduce Motion")
        Log.line("RESULT reduce motion: \(needsDots.count) needs-you dots, no halo")

        // 8. The title bar button while the sidebar is hidden goes to the pane elsewhere.
        try app.pressMenuKey("b")
        try await app.waitUntil("the sidebar is hidden") { model.sidebarCollapsed }
        try await app.waitUntil("the title bar button") {
            needsYouButtonShows(app) && app.text(of: "needs-you-button")?.contains("1 elsewhere needs you") == true
        }
        await app.sleep(0.5)  // The sidebar slides out.
        app.screenshot("title-bar-button")
        // Ticket 63: the window buttons do not cover the first tab. The tab starts after them, or
        // (with the toolbar of ticket 68) under the toolbar row that holds them.
        func tabBar(in view: NSView) -> (any FirstTabFraming)? {
            (view as? any FirstTabFraming) ?? view.subviews.lazy.compactMap(tabBar).first
        }
        if let content = app.window.contentView, let bar = tabBar(in: content), let first = bar.firstTabFrame,
           let zoom = app.window.standardWindowButton(.zoomButton) {
            let tab = bar.convert(first, to: nil as NSView?)
            let buttons = zoom.convert(zoom.bounds, to: nil)
            try expect(tab.minX >= buttons.maxX || tab.maxY <= buttons.minY,
                       "the first tab \(tab) sits under the zoom button \(buttons)")
        } else {
            throw DriverFailure("no tab bar, first tab, or zoom button to check")
        }
        try app.click("needs-you-button")
        try await app.waitUntil("the button reached the pane") {
            model.workspace.activePlotID == three && model.workspace.focusedPane == paneThree
        }
        try await app.waitUntil("the button goes when nothing elsewhere needs you") { !needsYouButtonShows(app) }
        try app.pressMenuKey("b")
        try await app.waitUntil("the sidebar shows") { !model.sidebarCollapsed }
        // The API error ended the turn, so a key gives idle.
        try await app.waitUntil("the pane has the keys") { app.window.firstResponder === (try? surface(paneThree)) }
        try app.type("x")
        try expect(state(paneThree) == .idle, "a key after an API error gave \(String(describing: state(paneThree)))")
    }
}
