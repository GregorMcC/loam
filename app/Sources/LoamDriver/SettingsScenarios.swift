import AppKit
import LoamKit

/// Driver scenario for the settings window (ticket 81). It uses the panel rig's temp store, so the
/// settings file is in the rig's `LOAM_HOME`, never in `~/.loam`.
@MainActor
extension Scenarios {
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    /// ⌘, opens Settings, and Open Ghostty Config has no key. The repo folders come from the file,
    /// and a hand edit of the file reaches the add repo suggestions.
    static func settings(_ app: DriverApp) async throws {
        do { try await settingsSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func settingsSteps(_ app: DriverApp) async throws {
        let rig = try PanelRig(outFolder: app.outFolder)
        _ = try rig.newPlot("Settings plot")
        let first = rig.root.appendingPathComponent("code-a")
        let second = rig.root.appendingPathComponent("code-b")
        for folder in [first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let file = SettingsFile(url: rig.loamHome.appendingPathComponent(SettingsFile.name))
        try #"{"repo_folders": ["\#(first.path)"], "theme_hint": "keep me"}"#
            .write(to: file.url, atomically: true, encoding: .utf8)

        let host = try await app.launchApp(client: rig.client, state: rig.stateFile)
        try check(host.model.panel.suggestionRoots == [first.path], "the suggestions do not use the file: \(host.model.panel.suggestionRoots)")

        // The Loam menu: Settings on ⌘,, and Open Ghostty Config with no key.
        let loamMenu = NSApp.mainMenu?.items.first?.submenu
        let settingsItem = loamMenu?.items.first { $0.title == "Settings\u{2026}" }
        try check(settingsItem?.keyEquivalent == "," && settingsItem?.keyEquivalentModifierMask == .command, "Settings is not on ⌘,")
        let openConfig = loamMenu?.items.first { $0.title == "Open Ghostty Config" }
        try check(openConfig != nil && openConfig?.keyEquivalent == "", "Open Ghostty Config still has the key \(openConfig?.keyEquivalent ?? "?")")

        try app.pressMenuKey(",")
        func settingsWindow() -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue == "dev.loam.settings" && $0.isVisible }
        }
        try await app.waitUntil("the settings window") { settingsWindow() != nil }
        try await app.waitUntil("the loam check", timeout: 10) { host.model.settings.loamStatus != .checking }
        Log.line("loam status: \(host.model.settings.loamStatus)")
        try check(host.model.settings.loamStatus != .checking, "the loam check did not finish")
        await app.sleep(0.5)
        app.screenshot("settings-general", of: settingsWindow())

        // A second ⌘, keeps one window.
        try app.pressMenuKey(",")
        await app.sleep(0.2)
        let count = NSApp.windows.filter { $0.identifier?.rawValue == "dev.loam.settings" }.count
        try check(count == 1, "⌘, made \(count) settings windows")

        // A change from the window is written, and keeps the key the app does not know.
        host.model.settings.addRepoFolder(second.path)
        try check(host.model.panel.suggestionRoots == [first.path, second.path], "the new folder did not reach the suggestions")
        let written = try String(contentsOf: file.url, encoding: .utf8)
        try check(written.contains("keep me") && written.contains(second.path), "the write lost a key: \(written)")

        // A hand edit applies at once.
        try #"{"repo_folders": ["\#(second.path)"], "theme_hint": "keep me"}"#
            .write(to: file.url, atomically: true, encoding: .utf8)
        try await app.waitUntil("the hand edit", timeout: 5) { host.model.panel.suggestionRoots == [second.path] }

        // Invalid JSON shows the error and is not replaced.
        try "{ broken".write(to: file.url, atomically: true, encoding: .utf8)
        try await app.waitUntil("the file error", timeout: 5) { host.model.settings.fileError != nil }
        host.model.settings.addRepoFolder(first.path)
        try check(try String(contentsOf: file.url, encoding: .utf8) == "{ broken", "Loam replaced an invalid file")
        await app.sleep(0.3)
        app.screenshot("settings-file-error", of: settingsWindow())

        // The Terminal tab.
        try #"{"repo_folders": ["~/Development"]}"#.write(to: file.url, atomically: true, encoding: .utf8)
        try await app.waitUntil("the fixed file", timeout: 5) { host.model.settings.fileError == nil }
        if let tabs = settingsWindow()?.contentViewController as? NSTabViewController {
            tabs.selectedTabViewItemIndex = 1
            await app.sleep(0.5)
            app.screenshot("settings-terminal", of: settingsWindow())
            tabs.selectedTabViewItemIndex = 0
        }
        settingsWindow()?.close()
    }
}
