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
            try await scrollIntoView(app, "run-defaults-mcp")
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

    /// TAS-64: the code review of the run defaults. The default is on. You turn it off, the effort picker goes off and
    /// `loam run defaults` shows it. You turn it on and pick an effort, and the core saves it. An empty effort is
    /// the default of Claude Code.
    static func runDefaultsReviewShot(_ app: DriverApp) async throws {
        do { try await runDefaultsReviewSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func runDefaultsReviewSteps(_ app: DriverApp) async throws {
        let (rig, environment, _) = try shotRig(app)
        let plot = try rig.newPlot("Loam v1 build")

        /// The `review` and the `review_effort` of the run defaults, as the core prints them, such as "review true, effort low".
        func saved() throws -> String {
            let defaults = try rig.json(["run", "defaults", plot])["defaults"] as? [String: Any]
            return "review \(defaults?["review"] as? Bool ?? false), effort \(defaults?["review_effort"] as? String ?? "?")"
        }

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        let model = host.model
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await app.sleep(1)
        try confirm(try saved() == "review true, effort ", "the default is not a review with the default effort")

        await model.showRecurring(plot: plot)
        try await app.waitUntil("the review controls show") {
            model.page == .recurring(plot) && app.exists("run-defaults-review") && model.runDefaults?.plotID == plot
        }
        try await scrollIntoView(app, "run-defaults-review")
        try await app.waitUntil("the effort picker is on") { AccessibilityProbe.shared.isEnabled("run-defaults-review-effort") }
        app.screenshot("run-defaults-review-on")

        // Pick an effort: the core saves it.
        try await app.openMenu(of: "run-defaults-review-effort")
        try await app.pickMenuItem("Extra high")
        try await app.waitUntil("the core saves the effort") { (try? saved()) == "review true, effort xhigh" }

        // Turn the review off: the core saves it, and the effort picker goes off but keeps its pick.
        try app.click("run-defaults-review")
        try await app.waitUntil("the core saves the switch") { (try? saved()) == "review false, effort xhigh" }
        try await app.waitUntil("the effort picker is off") { !AccessibilityProbe.shared.isEnabled("run-defaults-review-effort") }
        await app.sleep(0.5)
        app.screenshot("run-defaults-review-off")

        // Turn it on again: the picker is on, and the pick is still there.
        try app.click("run-defaults-review")
        try await app.waitUntil("the core saves the switch") { (try? saved()) == "review true, effort xhigh" }
        try await app.waitUntil("the effort picker is on again") { AccessibilityProbe.shared.isEnabled("run-defaults-review-effort") }
        NSApp.appearance = nil
    }

    /// Scrolls the page to its end and then up, until the element `id` is on screen. Then it scrolls `above` points
    /// further up, so the element is clear of the toolbar. It throws when the element never shows.
    private static func scrollIntoView(_ app: DriverApp, _ id: String, above: CGFloat = 160) async throws {
        let scroll = try unwrap(scrollView(in: app.window.contentView), "scroll view of the page")
        let end = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        var y = end
        while true {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            await app.sleep(0.4)
            AccessibilityProbe.shared.rescan()
            if app.windowPoint(of: id) != nil || y <= 0 { break }
            y = max(0, y - 120)
        }
        guard app.windowPoint(of: id) != nil else { throw DriverFailure("\(id) never came on screen") }
        guard above > 0 else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y - above)))
        scroll.reflectScrolledClipView(scroll.contentView)
        await app.sleep(0.4)
        AccessibilityProbe.shared.rescan()
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
