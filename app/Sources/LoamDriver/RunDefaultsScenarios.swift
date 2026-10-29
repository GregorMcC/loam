import AppKit
import Foundation
import LoamKit
import LoamTerminal

@MainActor
extension Scenarios {
    static func runDefaultsMCPShot(_ app: DriverApp) async throws {
        do { try await runDefaultsMCPSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// TAS-63: the MCP servers of the run defaults. The fake Claude Code config holds 3 servers in the user scope, one
    /// with a headersHelper, and a server in a local scope. The list must leave out the last 2. You select 1, and `loam run defaults` shows it. You clear it,
    /// and the list is empty. A selected server that the config lacks stays selected, shows "not found", and goes
    /// when you clear it by hand.
    private static func runDefaultsMCPSteps(_ app: DriverApp) async throws {
        let (rig, environment, _) = try shotRig(app)
        let plot = try rig.newPlot("Loam v1 build")
        // The servers are made up, and the config is in the fake CLAUDE_CONFIG_DIR, never the real one.
        let stdio = { (command: String) in ["type": "stdio", "command": command, "args": ["serve"]] }
        var config = (try? JSONSerialization.jsonObject(with: Data(contentsOf: rig.claudeJSON)) as? [String: Any]) ?? [:]
        config["mcpServers"] = ["docs-search": stdio("docs-search"), "notes-server": stdio("notes-server"),
                                "ticket-tracker": stdio("ticket-tracker"),
                                "token-server": ["type": "http", "url": "https://example.com/mcp", "headersHelper": "./token.sh"]]
        var projects = config["projects"] as? [String: Any] ?? [:]
        projects["/example/widgets"] = ["mcpServers": ["widgets-only": stdio("widgets-only")]]
        config["projects"] = projects
        try JSONSerialization.data(withJSONObject: config).write(to: rig.claudeJSON, options: .atomic)

        /// The `mcp_servers` of the run defaults, as the core prints them.
        func saved() throws -> [String] {
            let defaults = try rig.json(["run", "defaults", plot])["defaults"] as? [String: Any]
            return defaults?["mcp_servers"] as? [String] ?? []
        }

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        let model = host.model
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await app.sleep(1)
        try confirm(try saved().isEmpty, "the default is not no server")

        func showPicker() async throws {
            await model.showRecurring(plot: plot)
            try await app.waitUntil("the picker lists the servers") {
                model.page == .recurring(plot) && app.exists("run-defaults-mcp") && model.mcpServers?.count == 3
            }
            // The section is at the foot of the page, so the page scrolls to its end.
            let scroll = try unwrap(scrollView(in: app.window.contentView), "scroll view of the page")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            await app.sleep(0.5)
            AccessibilityProbe.shared.rescan()
        }
        try await showPicker()
        try confirm(model.mcpServers?.map(\.name) == ["docs-search", "notes-server", "ticket-tracker"],
                    "the list is \(String(describing: model.mcpServers))")
        try confirm(model.mcpServers?.allSatisfy { $0.scope == "user" } == true, "a server is not in the user scope")
        await app.sleep(0.5)
        app.screenshot("run-defaults-mcp-closed")

        // Select 1 server: the menu closes, the label counts it, and the core saved it.
        try await app.openMenu(of: "run-defaults-mcp")
        app.screenshot("run-defaults-mcp-menu", menu: menuWindow(of: app))
        try await app.pickMenuItem("notes-server \u{00B7} user")
        try await app.waitUntil("the core saves the server") { (try? saved()) == ["notes-server"] }
        try await app.waitUntil("the label counts 1 server") { app.text(of: "run-defaults-mcp")?.contains("1 MCP server") == true }
        try await app.openMenu(of: "run-defaults-mcp")
        await app.sleep(0.5)
        app.screenshot("run-defaults-mcp-checked", menu: menuWindow(of: app))

        // Clear it: the list is empty.
        try await app.pickMenuItem("notes-server \u{00B7} user")
        try await app.waitUntil("the core clears the list") { (try? saved()) == [] }
        try await app.waitUntil("the label says no server") { app.text(of: "run-defaults-mcp")?.contains("No MCP servers") == true }

        // A selected server that the list lacks stays selected and shows "not found". The app never drops it.
        try rig.loam(["run", "defaults", plot, "--mcp", "notes-server,retired-server"], extra: environment)
        await model.showIntake(plot: plot)
        try await showPicker()
        try await app.waitUntil("the label counts 2 servers") { app.text(of: "run-defaults-mcp")?.contains("2 MCP servers") == true }
        try confirm(try saved() == ["notes-server", "retired-server"], "the app changed a selection that it did not touch")
        try await app.openMenu(of: "run-defaults-mcp")
        await app.sleep(0.5)
        app.screenshot("run-defaults-mcp-not-found", menu: menuWindow(of: app))

        // You clear it by hand.
        try await app.pickMenuItem("retired-server \u{00B7} not found")
        try await app.waitUntil("the core drops the server") { (try? saved()) == ["notes-server"] }
        NSApp.appearance = nil
    }

    /// The menu window that shows over the driver window while a menu tracks the mouse, or nil.
    private static func menuWindow(of app: DriverApp) -> NSWindow? {
        NSApp.windows.first { $0 !== app.window && $0.isVisible && $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue }
    }

    /// The first scroll view under `view` whose content is taller than the view.
    private static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    private static func unwrap<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw DriverFailure("no \(what)") }
        return value
    }

    private static func confirm(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }
}
