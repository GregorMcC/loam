import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for the quick switcher (ticket 38). It drives the real window with ⌘P and a
/// few keys, on a temp store, a temp `state.json`, and a fake `LOAM_OPEN`.
@MainActor
extension Scenarios {
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func switcher(_ app: DriverApp) async throws {
        do { try await switcherSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func openSwitcher(_ app: DriverApp, actionsOnly: Bool = false) async throws {
        if actionsOnly {
            try pressExactMenuKey("p", [.command, .shift])
        } else {
            try app.pressMenuKey("p", flags: .command)
        }
        try await app.waitUntil("the switcher shows", timeout: 5) { app.exists("switcher-field") }
    }

    /// Performs the menu item whose key and modifiers equal these. `NSMenu.performKeyEquivalent`
    /// with a synthetic event ignores Shift, so ⌘P would run the ⌘⇧P item. This picks the item by its own key.
    private static func pressExactMenuKey(_ key: String, _ mask: NSEvent.ModifierFlags) throws {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.keyEquivalent == key, item.keyEquivalentModifierMask == mask, item.action != nil { return item }
                if let sub = item.submenu, let found = find(sub) { return found }
            }
            return nil
        }
        guard let main = NSApp.mainMenu, let item = find(main), let menu = item.menu else {
            throw DriverFailure("no menu item has the key \(key)")
        }
        menu.performActionForItem(at: menu.index(of: item))
    }

    private static func closed(_ app: DriverApp) async throws {
        try await app.waitUntil("the switcher closes", timeout: 5) { !app.exists("switcher-field") }
    }

    private static func switcherSteps(_ app: DriverApp) async throws {
        let rig = try PanelRig(outFolder: app.outFolder)
        let alpha = try rig.newPlot("Alpha plot")
        let beta = try rig.newPlot("Beta plot")
        try rig.loam(["link", "add", beta, "Zeta docs", "https://example.test/zeta"])

        let host = try await app.launchApp(client: rig.client, state: rig.stateFile)
        let model = host.model
        try await app.waitUntil("two plots") { model.plots.count == 2 && model.workspace.activePlotID != nil }

        // Beta holds two panes. The first has a terminal title. Alpha is active last.
        model.activate(plot: beta)
        model.openTab()
        guard let first = model.workspace.selectedTab(of: beta)?.focused else { throw DriverFailure("no pane") }
        model.setTerminalTitle("zebra build", of: first)
        model.openTab()
        model.activate(plot: alpha)

        // Empty query: the plot used last is first, and Escape closes.
        try await openSwitcher(app)
        try await app.waitUntil("the first row", timeout: 5) { app.exists("switcher-row-0") }
        try expect(app.text(of: "switcher-row-0")?.hasPrefix("Alpha plot") == true,
                   "row 0 is not the plot used last: \(app.text(of: "switcher-row-0") ?? "none")")
        try expect(!app.exists("switcher-row-5"), "the empty query lists links or actions")
        app.press(.escape)
        try await closed(app)

        // A pane, found by its terminal title.
        try await openSwitcher(app)
        try app.fill("switcher-field", with: "zebra")
        try await app.waitUntil("the pane row", timeout: 5) { app.text(of: "switcher-row-0")?.hasPrefix("zebra build") == true }
        app.screenshot("switcher-pane")
        // Ticket 90: the preview of a pane, with its footer.
        try await app.waitUntil("the pane preview", timeout: 5) {
            app.text(of: "switcher-preview-title") == "zebra build" && app.text(of: "switcher-preview-caption")?.hasPrefix("Pane") == true
        }
        try expect(app.text(of: "switcher-footer-action") == "Go to pane", "the footer says \(app.text(of: "switcher-footer-action") ?? "none")")
        app.press(.returnKey)
        try await closed(app)
        try await app.waitUntil("the pane has focus") {
            model.workspace.activePlotID == beta && model.workspace.selectedTab(of: beta)?.focused == first
        }

        // A plot.
        try await openSwitcher(app)
        try app.fill("switcher-field", with: "alpha")
        try await app.waitUntil("the plot row", timeout: 5) { app.text(of: "switcher-row-0")?.hasPrefix("Alpha plot") == true }
        try await app.waitUntil("the plot preview", timeout: 10) {
            app.text(of: "switcher-preview-title") == "Alpha plot" && app.text(of: "switcher-preview-caption") == "Plot · 0 panes · 0 links"
        }
        try expect(app.text(of: "switcher-footer-action") == "Open plot", "the footer says \(app.text(of: "switcher-footer-action") ?? "none")")
        app.screenshot("switcher-plot")
        app.press(.returnKey)
        try await closed(app)
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == alpha }

        // A link, from another plot, through `loam open`.
        try await openSwitcher(app)
        try app.fill("switcher-field", with: "zeta")
        try await app.waitUntil("the link row", timeout: 10) { app.text(of: "switcher-row-0")?.hasPrefix("Zeta docs") == true }
        try await app.waitUntil("the link preview", timeout: 5) { app.text(of: "switcher-preview-caption") == "Web link" }
        try expect(app.text(of: "switcher-footer-action") == "Open link", "the footer says \(app.text(of: "switcher-footer-action") ?? "none")")
        app.screenshot("switcher-link")
        app.press(.returnKey)
        try await closed(app)
        try await app.waitUntil("loam open ran", timeout: 10) { rig.openCalls.contains { $0.contains("example.test/zeta") } }

        // A menu action, with ⌘⇧P.
        let collapsed = model.sidebarCollapsed
        try await openSwitcher(app, actionsOnly: true)
        try await app.waitUntil("the field holds '>'", timeout: 5) { app.text(of: "switcher-field") == ">" }
        try app.fill("switcher-field", with: ">toggle sidebar")
        try await app.waitUntil("the action row", timeout: 5) { app.text(of: "switcher-row-0")?.hasPrefix("Toggle Sidebar") == true }
        app.press(.returnKey)
        try await closed(app)
        try await app.waitUntil("the sidebar toggled", timeout: 5) { model.sidebarCollapsed != collapsed }

        // A workspace change while the switcher is open (a pane event, a feed update) keeps the keyboard in the field.
        try await openSwitcher(app)
        model.openTab()
        await app.sleep(0.3)
        try expect(app.exists("switcher-field"), "the switcher closed on a workspace change")
        try expect(!(app.window.firstResponder is TerminalSurfaceView), "a workspace change gave the keys to the terminal")
        try app.fill("switcher-field", with: "q")
        try await app.waitUntil("the field holds the query", timeout: 5) { app.text(of: "switcher-field") == "q" }
        app.press(.escape)
        try await closed(app)

        // The use times reached the temp state.json. The writes wait up to 1 s, so they are joined.
        var times: [String: Double]?
        try? await app.waitUntil("use times in state.json", timeout: 10) {
            times = rig.stateFile.value(forKey: UseTimes.key) as? [String: Double]
            return times?["plot:\(alpha)"] != nil && times?["pane:\(first.uuidString)"] != nil
        }
        try expect(times?["plot:\(alpha)"] != nil && times?["pane:\(first.uuidString)"] != nil,
                   "state.json holds no use times: \(String(describing: times))")
    }
}
