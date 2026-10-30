import AppKit
import Foundation
import LoamKit

@MainActor
extension Scenarios {
    static func sandboxSettingsShot(_ app: DriverApp) async throws {
        do { try await sandboxSettingsSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// TAS-175: the sandbox settings. In the run defaults of a plot you add a host and a read path, and `loam run
    /// sandbox` shows them. A path that opens home is refused: it stays in the field, the reason shows, and the core
    /// stores nothing. You remove the read path. In Settings > Runs you add a path for every plot, and the plot
    /// scope does not change. All paths and hosts are made up.
    private static func sandboxSettingsSteps(_ app: DriverApp) async throws {
        let (rig, environment, _) = try shotRig(app)
        let plot = try rig.newPlot("Loam v1 build")

        /// One list of a scope, as the core prints it.
        func saved(_ list: String, plot: String? = nil) throws -> [String] {
            let args = ["run", "sandbox"] + (plot.map { [$0] } ?? [])
            return (try rig.json(args)["sandbox"] as? [String: Any])?[list] as? [String] ?? []
        }

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        let model = host.model
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await app.sleep(1)

        func scrollToEnd() async {
            guard let scroll = largestScrollView(in: app.window.contentView) else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            await app.sleep(0.5)
            AccessibilityProbe.shared.rescan()
        }
        func add(_ scope: String, _ list: String, _ text: String) async throws {
            try app.fill("sandbox-\(scope)-\(list)-field", with: text)
            try await app.waitUntil("Add is on") { AccessibilityProbe.shared.isEnabled("sandbox-\(scope)-\(list)-add") }
            try app.click("sandbox-\(scope)-\(list)-add")
        }

        await model.showRecurring(plot: plot)
        try await app.waitUntil("the sandbox lists") { model.page == .recurring(plot) && app.exists("sandbox-plot-hosts-field") }
        await scrollToEnd()
        try await add("plot", "hosts", "registry.example.com")
        try await app.waitUntil("the core saves the host") { (try? saved("hosts", plot: plot)) == ["registry.example.com"] }
        try await add("plot", "read", "~/.toolchains")
        try await app.waitUntil("the core saves the path") { (try? saved("read", plot: plot)) == ["~/.toolchains"] }
        try await app.waitUntil("the path shows") { app.exists("sandbox-plot-read-remove-~/.toolchains") }

        // A path that opens home is refused. It stays in the field, the reason shows, and nothing is stored.
        try await add("plot", "write", "~/.ssh")
        try await app.waitUntil("the reason shows") { app.text(of: "sandbox-plot-error")?.contains("not allowed") == true }
        try confirm(try saved("write", plot: plot).isEmpty, "the core stored a path that opens home")
        await scrollToEnd()
        app.screenshot("sandbox-plot-refused")

        // The reason goes when the next change works, and the machine scope does not change.
        try app.click("sandbox-plot-read-remove-~/.toolchains")
        try await app.waitUntil("the core drops the path") { (try? saved("read", plot: plot)) == [] }
        try await app.waitUntil("the reason goes") { !app.exists("sandbox-plot-error") }
        try confirm(try saved("hosts", plot: plot) == ["registry.example.com"], "removing a path changed the hosts")
        try confirm(try saved("read").isEmpty, "the plot scope changed the machine scope")
        await scrollToEnd()
        app.screenshot("sandbox-plot")

        // Settings > Runs: the machine scope.
        try app.pressMenuKey(",")
        func settingsWindow() -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue == "dev.loam.settings" && $0.isVisible }
        }
        try await app.waitUntil("the settings window") { settingsWindow() != nil }
        guard let tabs = settingsWindow()?.contentViewController as? NSTabViewController,
              let index = tabs.tabViewItems.firstIndex(where: { ($0.identifier as? String) == "Runs" })
        else { throw DriverFailure("the settings window has no Runs tab") }
        tabs.selectedTabViewItemIndex = index
        try await app.waitUntil("the machine lists", timeout: 30) { app.exists("sandbox-machine-read-field") }
        // The fields of this window take the text only while it has the keys.
        settingsWindow()?.makeKeyAndOrderFront(nil)
        await app.sleep(0.5)
        try await add("machine", "read", "/opt/example-toolchain")
        try await app.waitUntil("the core saves the machine path") { (try? saved("read")) == ["/opt/example-toolchain"] }
        try await add("machine", "hosts", "mirror.example.org")
        try await app.waitUntil("the core saves the machine host") { (try? saved("hosts")) == ["mirror.example.org"] }
        try confirm(try saved("hosts", plot: plot) == ["registry.example.com"], "the machine scope changed the plot scope")
        await app.sleep(0.5)
        app.screenshot("sandbox-machine", of: settingsWindow())
        settingsWindow()?.close()
        NSApp.appearance = nil
    }

    /// The scroll view under `view` with the tallest content, or nil.
    private static func largestScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        var best = (view as? NSScrollView).flatMap { scroll in
            (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height ? scroll : nil
        }
        for sub in view.subviews {
            if let found = largestScrollView(in: sub),
               (found.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = found }
        }
        return best
    }

    private static func confirm(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }
}
