import AppKit
import LoamKit
import LoamTerminal

/// Driver scenarios for the design system (ticket 55).
@MainActor
extension Scenarios {
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    /// The pane surface holds Display P3 values, so a pixel is near the token, not equal to it.
    private static func near(_ pixel: (Int, Int, Int), _ hex: UInt32) -> Bool {
        let want = [Int(hex >> 16) & 0xFF, Int(hex >> 8) & 0xFF, Int(hex) & 0xFF]
        return zip([pixel.0, pixel.1, pixel.2], want).allSatisfy { abs($0 - $1) <= 14 }
    }

    private static func hexString(_ pixel: (Int, Int, Int)) -> String {
        String(format: "%02x%02x%02x", pixel.0, pixel.1, pixel.2)
    }

    /// Loam's themes load by default and follow the appearance. A `theme` line in your own config wins.
    static func theme(_ app: DriverApp) async throws {
        let bedrock = LoamTheme.colorTokens.first { $0.name == "bedrock" }!
        try check(app.runtime.configDiagnostics.isEmpty, "the config has errors: \(app.runtime.configDiagnostics)")
        let pane = try app.addPane("A", command: "/bin/sh -c 'sleep 60'")

        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await app.waitUntil("the Night background", timeout: 10) {
            app.backgroundPixel(pane).map { near($0, bedrock.night) } ?? false
        }
        Log.line("RESULT night pixel #\(app.backgroundPixel(pane).map(hexString) ?? "?")")
        app.screenshot("terminal-night")

        NSApp.appearance = NSAppearance(named: .aqua)
        try await app.waitUntil("the Day background", timeout: 10) {
            app.backgroundPixel(pane).map { near($0, bedrock.day) } ?? false
        }
        Log.line("RESULT day pixel #\(app.backgroundPixel(pane).map(hexString) ?? "?")")
        app.screenshot("terminal-day")

        // Your own theme line wins over Loam's defaults, in both appearances.
        try app.writeConfig("theme = Dracula")
        try await app.waitUntil("your theme (Dracula, #282a36)", timeout: 10) {
            app.backgroundPixel(pane).map { near($0, 0x282a36) } ?? false
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await app.sleep(0.5)
        try check(app.backgroundPixel(pane).map { near($0, 0x282a36) } ?? false, "your theme lost in Night")
        Log.line("RESULT your theme wins")
        NSApp.appearance = nil
        _ = await app.close(pane)
    }

    /// Ticket 59: libghostty puts its own `GHOSTTY_RESOURCES_DIR` in each pane (the inherited
    /// value never arrives), and the Loam themes, the terminfo, and the shell integration work.
    /// The window title stays hidden with `macos-titlebar-style = transparent`.
    static func paneResources(_ app: DriverApp) async throws {
        try check(app.runtime.configDiagnostics.isEmpty, "the config has errors: \(app.runtime.configDiagnostics)")
        let resources = TerminalRuntime.resourcesFolder()
        try check(resources != nil, "no Ghostty resources folder. Run scripts/build-ghosttykit.sh")
        try check(ProcessInfo.processInfo.environment[TerminalRuntime.resourcesVariable] == resources,
                  "the app process lost its resources folder")

        // The first pane: `env` shows the whole pane environment.
        let file = "\(app.outFolder)/pane-resources-env.txt"
        try? FileManager.default.removeItem(atPath: file)
        let plain = try app.addPane("A", command: "/bin/sh -c 'env > pane-resources-env.txt; echo env-written; sleep 30'")
        try await app.waitUntil("env-written") { app.lines(plain).contains("env-written") }
        let text = try String(contentsOfFile: file, encoding: .utf8)
        let keys = text.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
        try check(text.contains("GHOSTTY_RESOURCES_DIR=\(resources!)\n"), "the pane has a resources folder that is not Loam's")
        try check(text.contains("TERM=xterm-ghostty\n"), "the pane has no xterm-ghostty TERM")
        try check(keys.contains("TERMINFO"), "the pane has no TERMINFO")
        Log.line("RESULT the pane has only Loam's resources folder")

        // The Loam theme applies.
        let bedrock = LoamTheme.colorTokens.first { $0.name == "bedrock" }!
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await app.waitUntil("the Night background", timeout: 10) {
            app.backgroundPixel(plain).map { near($0, bedrock.night) } ?? false
        }
        NSApp.appearance = nil
        _ = await app.close(plain)

        // A zsh pane: terminfo resolves and the shell integration is on.
        let shell = try app.addPane("B", command: "/bin/zsh")
        // Your zsh startup files set the prompt, so the pane gets the input and answers when it is ready.
        await app.sleep(1)
        try app.type("echo \"res=${GHOSTTY_RESOURCES_DIR-unset} features=${GHOSTTY_SHELL_FEATURES:+on}\"; infocmp xterm-ghostty >/dev/null && echo terminfo-ok")
        app.press(.returnKey)
        try await app.waitUntil("the zsh output", timeout: 20) { app.lines(shell).contains("terminfo-ok") }
        let output = app.lines(shell)
        try check(output.contains("res=\(resources!) features=on"), "the zsh pane has the wrong variables: \(output.suffix(6))")
        Log.line("RESULT terminfo and shell integration work")
        _ = await app.close(shell)

        // The window title stays hidden for the default style, and again after a config change.
        try check(app.runtime.windowAppearance.titlebarStyle == "transparent", "not the default titlebar style")
        app.window.titleVisibility = .visible
        app.runtime.applyWindowAppearance(to: app.window)
        try check(app.window.titleVisibility == .hidden, "the title shows with macos-titlebar-style = transparent")
        try app.writeConfig("macos-titlebar-style = tabs")
        await app.sleep(0.5)
        app.runtime.applyWindowAppearance(to: app.window)
        try check(app.window.titleVisibility == .hidden, "the title shows with macos-titlebar-style = tabs")
        Log.line("RESULT title stays hidden")
    }

    /// The main window in Night and Day, with the sidebar, tabs, panes, and the plot panel.
    static func windowShot(_ app: DriverApp) async throws {
        do { try await windowShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func windowShotSteps(_ app: DriverApp) async throws {
        let rig = try PanelRig(outFolder: app.outFolder)
        let plot = try rig.newPlot("Loam v1 build")
        try rig.loam(["set", plot, "what", "A macOS terminal on libghostty that seeds Claude Code sessions."])
        try rig.loam(["set", plot, "why", "Each session knows the purpose and the key documents at once."])
        try rig.loam(["set", plot, "where-it-stands", "The design system lands in the app."])
        let note = rig.vault.appendingPathComponent("Notes/Note.md").path
        try rig.loam(["link", "add", plot, "Design spec", note])
        try rig.loam(["link", "add", plot, "Repository", "https://github.com/GregorMcC/loam"])
        try rig.loam(["link", "add", plot, "Gone folder", "/nonexistent-loam-driver/Gone"])
        _ = try rig.newPlot("Client onboarding")
        _ = try rig.newPlot("Release notes")

        let host = try await app.launchApp(client: rig.client, state: rig.stateFile)
        try await app.waitUntil("a plot is active") { host.model.workspace.activePlotID != nil }
        host.model.activate(number: 1)
        host.model.openTab()
        host.model.split(.sideBySide)
        host.model.openTab()
        host.model.activate(number: 2)
        host.model.openTab()
        host.model.activate(number: 1)
        try await app.openPanel(host)
        try await rig.claudeSetsWhere(plot, "The design system is in the app, in Night and Day.")
        try await app.waitUntil("the new change", timeout: 10) { app.exists("panel-new-since") }
        try check(app.exists("tab-bar"), "the tab bar is missing")

        NSApp.appearance = NSAppearance(named: .darkAqua)
        await app.sleep(0.8)
        app.screenshot("night")
        NSApp.appearance = NSAppearance(named: .aqua)
        await app.sleep(0.8)
        app.screenshot("day")
        NSApp.appearance = nil
    }

    /// Ticket 65: a plot with no panes and the plot panel open. The hint wraps inside the pane area.
    static func emptyHint(_ app: DriverApp) async throws {
        let rig = try PanelRig(outFolder: app.outFolder)
        _ = try rig.newPlot("Empty plot")
        let host = try await app.launchApp(client: rig.client, state: rig.stateFile)
        try await app.openPanel(host)
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == "empty-hint" { return view }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        guard let root = app.window.contentView, let hint = find(root), let area = hint.superview else {
            throw DriverFailure("the empty hint is missing")
        }
        await app.sleep(0.3)
        Log.line("RESULT hint \(hint.frame) in pane area \(area.bounds)")
        app.screenshot("empty-hint")
        try check(!hint.isHidden && hint.frame.width > 0 && hint.frame.height > 0, "the hint does not show")
        try check(area.bounds.contains(hint.frame), "the hint \(hint.frame) leaves the pane area \(area.bounds)")
    }
}
