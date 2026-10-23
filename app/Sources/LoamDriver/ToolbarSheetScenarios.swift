import AppKit
import LoamKit

/// Driver scenario for ticket 126: the scrim of a sheet over the title bar. While the New worktree sheet shows, the scrim
/// covers the title bar and the toolbar, the window buttons stay clear, and no toolbar item takes a press. With the sheet
/// closed, the scrim is gone and the items act again. It uses a made-up plot in a temp `LOAM_HOME`.
@MainActor
extension Scenarios {
    private static func expectToolbar(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func toolbarSheet(_ app: DriverApp) async throws {
        do { try await toolbarSheetSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// The view with this accessibility ID, in the frame of the window (the content view, the title bar and the overlays).
    private static func find(_ id: String, in view: NSView) -> NSView? {
        view.accessibilityIdentifier() == id ? view : view.subviews.lazy.compactMap { find(id, in: $0) }.first
    }

    /// The centre of a view in the coordinates of the frame of the window.
    private static func centre(of view: NSView, in frame: NSView) -> NSPoint {
        frame.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
    }

    /// Checks the scrim over the title bar: shown and over the toolbar, or not shown. It waits for the fade in.
    static func expectTitleBarScrim(_ app: DriverApp, _ host: AppHost, shown: Bool) async throws {
        guard let frame = host.window.contentView?.superview, let content = host.window.contentView,
              let bar = find("title-bar-scrim", in: frame), let buttons = find("title-bar-scrim-buttons", in: frame)
        else { throw DriverFailure("the frame of the window has no scrim over the title bar") }
        guard shown else {
            try await app.waitUntil("the scrim over the title bar goes") { bar.isHidden && buttons.isHidden }
            return
        }
        try await app.waitUntil("the scrim over the title bar fades in") {
            !bar.isHidden && bar.alphaValue == 1 && !buttons.isHidden && buttons.alphaValue == 1
        }
        // The bar ends where the safe area begins, which is where the scrim of the sheet begins.
        try expectToolbar(abs(bar.frame.height - content.safeAreaInsets.top) < 0.5 && bar.frame.height > 0,
                          "the scrim is \(bar.frame.height) high, and the title bar is \(content.safeAreaInsets.top)")
        try expectToolbar(abs(bar.frame.maxY - frame.bounds.maxY) < 0.5, "the scrim does not start at the top of the window")
        // The bar and the scrim of the sheet meet: the hosting view of the sheet has the same inset as the bar is high. A press
        // on the bar moves the window, as on the title bar.
        let hosts = content.subviews.filter { String(describing: Swift.type(of: $0)).contains("NSHostingView") && !$0.isHidden && $0.frame == content.bounds }
        for hosting in hosts {
            try expectToolbar(abs(hosting.safeAreaInsets.top - bar.frame.height) < 0.5,
                              "the sheet starts \(hosting.safeAreaInsets.top) down, and the scrim over the title bar is \(bar.frame.height) high")
        }
        try expectToolbar(bar.mouseDownCanMoveWindow, "a press on the scrim over the title bar does not move the window")
        // The scrim is over the toolbar: a press on its items lands on the scrim.
        for id in ["new-session-button", "panel-button"] {
            guard let item = find(id, in: frame) else { throw DriverFailure("no toolbar item \(id)") }
            let hit = frame.hitTest(centre(of: item, in: frame))
            try expectToolbar(hit === bar, "a press on \(id) lands on \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nothing"), not the scrim")
        }
        // The window buttons stay clear and stay live. The ground behind them has its own scrim.
        guard let close = host.window.standardWindowButton(.closeButton) else { throw DriverFailure("no close button") }
        let closePoint = centre(of: close, in: frame)
        try expectToolbar(frame.hitTest(closePoint) !== bar, "the scrim takes the press on the close button")
        try expectToolbar(buttons.frame.contains(closePoint), "the dim behind the window buttons is not behind the close button")
        // Where the bar and the dim behind the window buttons meet, no point has both.
        try expectToolbar(bar.frame.minY <= buttons.frame.minY + 0.5 && buttons.frame.maxY <= bar.frame.maxY + 0.5,
                          "the dim behind the window buttons is outside the title bar")
    }

    private static func toolbarSheetSteps(_ app: DriverApp) async throws {
        let rig = try PanelRig(outFolder: app.outFolder)
        let plot = try rig.newPlot("Widgets plot")
        let host = try await app.launchApp(client: LoamClient(binary: rig.binary, environment: rig.environment), state: rig.stateFile)
        host.window.setFrame(NSRect(x: 80, y: 80, width: 1200, height: 720), display: true)
        let model = host.model
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }
        model.openTab(.session)
        try await app.waitUntil("the tab shows") { app.exists("new-session-button") }
        guard let toolbar = host.window.toolbar else { throw DriverFailure("the window has no toolbar") }
        func item(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? { toolbar.items.first { $0.itemIdentifier == id } }

        // 1. No sheet: the scrim is gone, and every item is on.
        try await expectTitleBarScrim(app, host, shown: false)
        let appKitItems = try expectAppKitItemsOn(host)
        for id in ["new-session-button", "panel-button"] {
            try expectToolbar(AccessibilityProbe.shared.isEnabled(id), "\(id) is off with no sheet")
        }
        try expectToolbar(item(.toggleSidebar)?.isEnabled == true, "the sidebar button is off with no sheet")

        // 2. The New worktree sheet shows: the scrim covers the title bar, and every item is off.
        try expectToolbar(model.openNewWorktree(plot: plot), "the New worktree sheet did not open")
        try await app.waitUntil("the sheet shows") { app.exists("new-worktree-start") }
        try await expectTitleBarScrim(app, host, shown: true)
        try await app.waitUntil("the items go off") {
            !AccessibilityProbe.shared.isEnabled("new-session-button") && !AccessibilityProbe.shared.isEnabled("panel-button")
                && item(.toggleSidebar)?.isEnabled == false
        }
        // A press on an item that is off does nothing: no tab, no panel, no sidebar change. The accessibility call may still
        // report success for a button that is off, so the state tells.
        let tabs = model.workspace.tabs(of: .plot(plot)).count
        let panelShows = model.panel.visible
        let sidebarHidden = model.sidebarCollapsed
        for id in ["new-session-button", "panel-button"] { _ = AccessibilityProbe.shared.press(id) }
        await app.sleep(0.5)
        try expectToolbar(model.workspace.tabs(of: .plot(plot)).count == tabs, "a toolbar press opened a tab under the sheet")
        try expectToolbar(model.panel.visible == panelShows, "a toolbar press changed the plot panel under the sheet")
        try expectToolbar(model.sidebarCollapsed == sidebarHidden, "a toolbar press changed the sidebar under the sheet")
        // The items that AppKit adds for a window (ticket 132) are off, as under a native sheet.
        try expectAppKitItemsOff(host, baseline: appKitItems)
        app.screenshot("toolbar-under-sheet")
        // A resize moves the window buttons, so the scrim follows them, and the bar keeps the height of the title bar.
        host.window.setFrame(NSRect(x: 100, y: 100, width: 1000, height: 640), display: true)
        try await expectTitleBarScrim(app, host, shown: true)
        // AppKit may add the title bar again, as it can in full screen. The next layout puts the scrim back on top.
        if let frame = host.window.contentView?.superview,
           let titleBar = frame.subviews.first(where: { String(describing: Swift.type(of: $0)).contains("TitlebarContainer") }) {
            frame.addSubview(titleBar, positioned: .above, relativeTo: nil)
            host.window.setFrame(NSRect(x: 100, y: 100, width: 1100, height: 660), display: true)
            try await expectTitleBarScrim(app, host, shown: true)
        }

        // 3. The sheet closes: the scrim goes, and the items act. New session opens a tab, so the item works.
        model.closeNewWorktree()
        try await app.waitUntil("the sheet closes") { !app.exists("new-worktree-sheet") }
        try await expectTitleBarScrim(app, host, shown: false)
        try await app.waitUntil("the items come back") {
            AccessibilityProbe.shared.isEnabled("new-session-button") && AccessibilityProbe.shared.isEnabled("panel-button")
                && item(.toggleSidebar)?.isEnabled == true
        }
        try app.click("new-session-button")
        try await app.waitUntil("New session opens a tab") { model.workspace.tabs(of: .plot(plot)).count == tabs + 1 }
        try expectToolbar(appKitItemStates(host) == appKitItems, "an AppKit item stayed off after the sheet")

        // 4. A native sheet (ticket 128): New Plot… asks for a name in a sheet. The commands that act on the window are off while
        // it shows, as under the sheets of Loam. Cancel closes it, and the commands run again.
        try expectToolbar(app.sendMenuKey("n"), "the main menu took no \u{2318}N")
        try await app.waitUntil("the name sheet shows") { host.window.attachedSheet != nil }
        try await expectKeysOffUnderSheet(app, host, plot: plot)
        guard let nameSheet = host.window.attachedSheet else { throw DriverFailure("a key closed the name sheet") }
        host.window.endSheet(nameSheet, returnCode: .alertSecondButtonReturn)
        try await app.waitUntil("the name sheet closes") { host.window.attachedSheet == nil }
        try expectWindowItems(enabled: true)
        try expectToolbar(app.sendMenuKey("t"), "the main menu took no \u{2318}T")
        try await app.waitUntil("\u{2318}T opens a tab again") { model.workspace.tabs(of: .plot(plot)).count == tabs + 2 }
    }
}
