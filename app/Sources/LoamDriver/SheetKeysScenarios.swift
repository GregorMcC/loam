import AppKit
import LoamKit
import LoamTerminal

/// The check of ticket 128, for the scenarios that open a sheet: the keys and the menu items under an open sheet, a Loam sheet
/// or a native one. Every menu item that acts on the window is off, and its key does nothing. The items of the app stay on.
/// The sheet keeps its keys. Ticket 132 adds the items that AppKit adds for a window (Hide Toolbar, Enter Full Screen, Zoom).
@MainActor
extension Scenarios {
    /// A menu item that acts on the window, with its key.
    private struct WindowItem {
        var title: String
        var key: String
        var mask: NSEvent.ModifierFlags
    }

    private static let windowItems = [
        WindowItem(title: "New Tab", key: "t", mask: .command),
        WindowItem(title: "New Shell Tab", key: "t", mask: [.command, .option]),
        WindowItem(title: "New Plot\u{2026}", key: "n", mask: .command),
        WindowItem(title: "Close", key: "w", mask: .command),
        WindowItem(title: "Toggle Sidebar", key: "b", mask: .command),
        WindowItem(title: "Plot Panel", key: "i", mask: .command),
        WindowItem(title: "Quick Switcher", key: "p", mask: .command),
        WindowItem(title: "Quick Switcher: Actions", key: "p", mask: [.command, .shift]),
        WindowItem(title: "Actions", key: "j", mask: .command),
        WindowItem(title: "Next Pane That Needs You", key: "l", mask: .command),
        WindowItem(title: "Next Worktree Ready to Merge", key: "l", mask: [.command, .shift]),
        WindowItem(title: "Home", key: "0", mask: .control),
        WindowItem(title: "Plot 1", key: "1", mask: .control),
    ]

    /// The items of the app: Settings, the Ghostty config and Quit.
    private static let appItems = ["Settings\u{2026}", "Open Ghostty Config", "Reload Ghostty Config", "Quit Loam"]

    private static func menuItem(titled title: String) -> NSMenuItem? {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.title == title, item.action != nil { return item }
                if let submenu = item.submenu, let found = find(submenu) { return found }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }

    /// Checks the menu bar: each item that acts on the window is on or off, and each item of the app is on. With a sheet
    /// open, the menu has to draw the items off before a key can do nothing.
    static func expectWindowItems(enabled: Bool) throws {
        // The menu validates its own items only, so each submenu validates its own.
        for top in NSApp.mainMenu?.items ?? [] { top.submenu?.update() }
        // These always have a space and a plot. The other items can be off for their own reasons.
        let alwaysOn = ["New Tab", "Toggle Sidebar", "Plot Panel", "Quick Switcher", "Actions"]
        for item in windowItems where enabled ? alwaysOn.contains(item.title) : true {
            guard let found = menuItem(titled: item.title) else { throw DriverFailure("the menu has no item \(item.title)") }
            if found.isEnabled != enabled { throw DriverFailure("\(item.title) is \(found.isEnabled ? "on" : "off") in the menu") }
        }
        for title in appItems {
            guard let found = menuItem(titled: title) else { throw DriverFailure("the menu has no item \(title)") }
            if !found.isEnabled { throw DriverFailure("\(title) is off in the menu") }
        }
    }

    /// An item that AppKit adds for a window (ticket 132), and whether macOS turns it off under a native sheet. The sheet is the
    /// key window then, and a sheet has none of these. A sheet of Loam is a view in the window, so the window has to turn them
    /// off. Minimize and the window list stay on under a native sheet.
    private struct AppKitItem {
        var title: String
        var action: Selector
        var offUnderSheet: Bool
    }

    private static let appKitItems = [
        AppKitItem(title: "Hide Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)), offUnderSheet: true),
        AppKitItem(title: "Customize Toolbar", action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), offUnderSheet: true),
        AppKitItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), offUnderSheet: true),
        AppKitItem(title: "Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), offUnderSheet: true),
        AppKitItem(title: "Show All Tabs", action: #selector(NSWindow.toggleTabOverview(_:)), offUnderSheet: true),
        AppKitItem(title: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), offUnderSheet: true),
        AppKitItem(title: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), offUnderSheet: true),
        AppKitItem(title: "Move Tab to New Window", action: #selector(NSWindow.moveTabToNewWindow(_:)), offUnderSheet: true),
        AppKitItem(title: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), offUnderSheet: true),
        AppKitItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), offUnderSheet: true),
        AppKitItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), offUnderSheet: true),
        AppKitItem(title: "Minimize Window", action: #selector(NSWindow.performMiniaturize(_:)), offUnderSheet: false),
        AppKitItem(title: "Window list", action: #selector(NSWindow.makeKeyAndOrderFront(_:)), offUnderSheet: false),
    ]

    /// What the window answers for each AppKit item, as the menu asks it. AppKit sends an item with no target to the window, and
    /// a background run has no key window, so the menu bar of the driver cannot show this. The answer is the same.
    static func appKitItemStates(_ host: AppHost) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: appKitItems.map {
            ($0.title, host.window.validateMenuItem(NSMenuItem(title: $0.title, action: $0.action, keyEquivalent: "")))
        })
    }

    /// With no sheet, the window answers on for Hide Toolbar and Zoom, so the check under a sheet tests something. It returns the
    /// answers, to compare after the sheet. It also logs the items of the menu bar that have no command of Loam, which are the
    /// items that AppKit adds and the items of the app.
    static func expectAppKitItemsOn(_ host: AppHost) throws -> [String: Bool] {
        let states = appKitItemStates(host)
        for title in ["Hide Toolbar", "Zoom", "Close Window", "Minimize Window", "Window list"] where states[title] != true {
            throw DriverFailure("\(title) is off with no sheet")
        }
        for top in NSApp.mainMenu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            submenu.update()
            let plain = submenu.items.filter { !$0.isSeparatorItem && $0.representedObject == nil }.map {
                "\($0.title) (\($0.action.map(NSStringFromSelector) ?? "no action"), \($0.isEnabled ? "on" : "off")\($0.isHidden ? ", hidden" : ""))"
            }
            Log.line("menu \(submenu.title): items with no command of Loam: \(plain.isEmpty ? "none" : plain.joined(separator: "; "))")
        }
        return states
    }

    /// A sheet of Loam shows or holds the window: the window turns off each AppKit item that macOS turns off under a native
    /// sheet, and leaves the others as they were (`baseline`, or on). Any such item in the menu bar is off too.
    static func expectAppKitItemsOff(_ host: AppHost, baseline: [String: Bool]? = nil) throws {
        let states = appKitItemStates(host)
        for item in appKitItems {
            if item.offUnderSheet {
                if states[item.title] != false { throw DriverFailure("\(item.title) is on under the sheet") }
            } else if states[item.title] != (baseline?[item.title] ?? true) {
                throw DriverFailure("\(item.title) changed under the sheet")
            }
        }
        for top in NSApp.mainMenu?.items ?? [] { top.submenu?.update() }
        func check(_ menu: NSMenu) throws {
            for item in menu.items {
                if let action = item.action, appKitItems.contains(where: { $0.offUnderSheet && $0.action == action }), item.isEnabled {
                    throw DriverFailure("\(item.title) is on in the menu under the sheet")
                }
                if let submenu = item.submenu { try check(submenu) }
            }
        }
        if let main = NSApp.mainMenu { try check(main) }
    }

    /// A sheet is open over the window of `plot`: the Land sheet, the New worktree sheet, or a native sheet. Every menu item
    /// that acts on the window draws off. Its key through the menu, its key through the window, its action sent by hand and
    /// the command of a Ghostty key change nothing: no tab, no panel, no sidebar, no overlay, and the sheet stays open. The
    /// caller closes the sheet.
    static func expectKeysOffUnderSheet(_ app: DriverApp, _ host: AppHost, plot: String) async throws {
        let model = host.model
        guard model.sheetIsOpen || host.window.attachedSheet != nil else { throw DriverFailure("no sheet is open") }
        try expectWindowItems(enabled: false)
        // A sheet of Loam: the window answers for the AppKit items. A native sheet is the key window, so AppKit answers then.
        if model.sheetBlocksWindow { try expectAppKitItemsOff(host) }

        func state() -> String {
            "tabs \(model.workspace.tabs(of: .plot(plot)).count), selected \(String(describing: model.workspace.selectedTab(of: .plot(plot))?.id)), "
                + "active \(String(describing: model.workspace.activePlotID)), panel \(model.panel.visible), "
                + "sidebar \(model.sidebarCollapsed), switcher \(model.switcher.isOpen), menu \(app.exists("actions-menu")), "
                + "sheet \(model.landSheet.isOpen), \(model.newWorktreeSheet.isOpen), native \(host.window.attachedSheet.map(ObjectIdentifier.init) as Any)"
        }
        let before = state()

        // The key through the main menu, as AppKit sends it when no view takes it. The menu takes the key of an item that is off
        // and does nothing. A pane that has the keys never sees it, so a Ghostty binding such as close_surface does not run.
        for item in windowItems {
            guard let letter = item.key.first else { continue }
            if !(try app.sendMenuKey(letter, flags: item.mask)) { throw DriverFailure("the main menu did not take the key of \(item.title)") }
        }
        // The action of each item sent by hand, as the quick switcher sends it.
        for item in windowItems {
            guard let found = menuItem(titled: item.title), let menu = found.menu else { continue }
            menu.performActionForItem(at: menu.index(of: found))
        }
        // The key through the window, as the driver sends every key. ⌘T and ⌘I are the keys of the ticket.
        app.press(letter: "t", flags: .command)
        app.press(letter: "i", flags: .command)
        // The command of a fixed key or a Ghostty key in a pane. It does nothing, so a binding goes on to the terminal.
        for command: AppCommand in [.newTab, .togglePlotPanel, .toggleSidebar, .quickSwitcher, .actionsMenu, .nextPaneThatNeedsYou,
                                    .closePane, .selectHome] {
            if app.runtime.commandHandler?(command) == true { throw DriverFailure("the command \(command) ran under the sheet") }
        }
        await app.sleep(0.5)

        let after = state()
        if after != before { throw DriverFailure("a key changed the window under the sheet.\nbefore: \(before)\nafter:  \(after)") }
        try expectWindowItems(enabled: false)
    }
}
