import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 89: the bottom action bar and the actions menu (⌘J).
@MainActor
extension Scenarios {
    private static func expectThat(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func actions(_ app: DriverApp) async throws {
        do { try await actionsSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func actionsSteps(_ app: DriverApp) async throws {
        let (rig, environment, extra) = try shotRig(app)
        let plot = try rig.newPlot("Loam v1 build")
        try rig.loam(["set", plot, "what", "A macOS terminal on libghostty that seeds Claude Code sessions."])
        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        try await app.waitUntil("a plot is active") { host.model.workspace.activePlotID == plot }
        host.model.openTab()
        try await app.waitUntil("a pane has the keys", timeout: 10) {
            guard let pane = host.model.workspace.focusedPane else { return false }
            return host.window.firstResponder === host.paneView(pane)
        }
        func tab() -> Tab? { host.model.workspace.selectedTab(of: plot) }

        // The bar names the plot and the focused pane, and has New session and Actions with keycaps.
        try await app.waitUntil("the bar names the plot") { app.text(of: "action-bar-plot") == "Loam v1 build" }
        try await app.waitUntil("the bar names the pane") { app.exists("action-bar-pane") }
        try expectThat(app.exists("action-bar-new-session") && app.exists("action-bar-actions"), "the bar has no buttons")

        // A change by Claude shows as a toast in the bar.
        try await rig.claudeSetsWhere(plot, "The bar and the actions menu are built.")
        try await app.waitUntil("the toast shows", timeout: 10) {
            app.text(of: "action-bar-toast")?.contains("Claude set Where it stands") == true
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await app.sleep(1)
        app.screenshot("night-bar")

        // ⌘J from the pane opens the menu, with the search field focused.
        app.press(letter: "j", flags: .command)
        try await app.waitUntil("the menu opens") { app.exists("actions-menu") }
        let rows = ["New session", "Split right", "Split down", "Split right with shell", "Split down with shell", "Close pane", "Edit brief", "Add link", "Add repo", "Archive plot"]
        try await app.waitUntil("the menu lists the pane and plot actions") {
            rows.allSatisfy { app.exists("actions-row-\($0)") }
        }
        try await app.waitUntil("the search field has the keys") { host.window.firstResponder is NSTextView }
        await app.sleep(0.5)
        app.screenshot("night-menu")

        // ⌘J again closes it, and the pane has the keys again.
        try app.pressMenuKey("j")
        try await app.waitUntil("⌘J closes the menu") { !app.exists("actions-menu") }
        try await app.waitUntil("the pane has the keys again") {
            host.model.workspace.focusedPane.map { host.window.firstResponder === host.paneView($0) } ?? false
        }

        // Escape closes it.
        app.press(letter: "j", flags: .command)
        try await app.waitUntil("the menu opens again") { app.exists("actions-menu") }
        try await app.waitUntil("the search field has the keys") { host.window.firstResponder is NSTextView }
        app.press(.escape)
        try await app.waitUntil("Escape closes the menu") { !app.exists("actions-menu") }

        // A filter and Return run the action: Split down splits the focused pane.
        try app.click("action-bar-actions")
        try await app.waitUntil("a click on Actions opens the menu") { app.exists("actions-menu") }
        try await app.waitUntil("the search field has the keys") { host.window.firstResponder is NSTextView }
        try app.type("down")
        try await app.waitUntil("the filter leaves Split down") {
            app.exists("actions-row-Split down") && !app.exists("actions-row-Split right")
        }
        app.screenshot("night-menu-filter")
        app.press(.returnKey)
        try await app.waitUntil("Return splits the pane", timeout: 10) {
            tab()?.tree.paneIDs.count == 2 && !app.exists("actions-menu")
        }
        if case .split(let axis, _, _, _) = tab()?.tree {
            try expectThat(axis == .stacked, "the split is \(axis), not down")
        }

        // Split right with shell opens a shell next to the focused pane (ticket 97).
        app.press(letter: "j", flags: .command)
        try await app.waitUntil("the menu opens for a shell split") { app.exists("actions-menu") }
        try await app.waitUntil("the search field has the keys") { host.window.firstResponder is NSTextView }
        try app.type("shell right")
        try await app.waitUntil("the filter leaves Split right with shell") {
            app.exists("actions-row-Split right with shell") && !app.exists("actions-row-Split down with shell")
        }
        app.press(.returnKey)
        try await app.waitUntil("Return splits with a shell", timeout: 10) {
            tab()?.tree.paneIDs.count == 3 && !app.exists("actions-menu")
        }
        let shellPane = host.model.workspace.focusedPane
        try expectThat(shellPane.flatMap { host.model.workspace.spec(of: $0)?.kind } == .shell, "the new pane is not a shell")

        // A plot action: Add link opens the panel with the add link row.
        app.press(letter: "j", flags: .command)
        try await app.waitUntil("the menu opens for a plot action") { app.exists("actions-menu") }
        try await app.waitUntil("the search field has the keys") { host.window.firstResponder is NSTextView }
        try app.type("add link")
        app.press(.returnKey)
        try await app.waitUntil("Add link opens the panel and its row", timeout: 10) {
            app.exists("plot-panel") && app.exists("panel-new-link-target")
        }
        try app.click("panel-add-cancel")

        // Day and a third-party theme, with the panel open. The bar ends where the well ends, so
        // it is narrower now, and the toast shows only while it fits.
        try await app.waitUntil("the toast fades", timeout: ActionBarModel.toastSeconds + 5) { !app.exists("action-bar-toast") }
        for (name, appearance, theme) in [("day", NSAppearance.Name.aqua, ""), ("catppuccin", .darkAqua, "theme = Catppuccin Mocha\n")] {
            if !theme.isEmpty {
                try app.writeConfig(extra + "\n" + theme)
                app.runtime.reloadConfig()
                try await app.waitUntil("the chrome follows Catppuccin Mocha", timeout: 10) {
                    ChromePalette.shared.current?.bedrock == 0x1e1e2e
                }
            }
            NSApp.appearance = NSAppearance(named: appearance)
            try await app.waitUntil("\(name): the window follows", timeout: 10) {
                (host.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) == (appearance == .darkAqua)
            }
            try await rig.claudeSetsWhere(plot, "Shot in \(name).")
            try await app.waitUntil("\(name): the panel runs the full height", timeout: 5) {
                guard let panel = panelItem(host)?.viewController.view,
                      let split = panel.superview else { return false }
                return abs(panel.frame.height - split.bounds.height) < 1
            }
            await app.sleep(1)
            app.screenshot("\(name)-bar")
            app.press(letter: "j", flags: .command)
            try await app.waitUntil("\(name): the menu opens") { app.exists("actions-menu") }
            await app.sleep(0.6)
            app.screenshot("\(name)-menu")
            app.press(.escape)
            try await app.waitUntil("\(name): the menu closes") { !app.exists("actions-menu") }
        }
        NSApp.appearance = nil
    }
}
