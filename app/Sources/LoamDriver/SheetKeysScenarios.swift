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

    /// An item that AppKit sends to a window (ticket 132), and whether macOS turns it off under a native sheet. The sheet is the
    /// key window then, and a sheet has none of these. A sheet of Loam is a view in the window, so the window has to turn them
    /// off. Minimize and the Window list stay on under a native sheet. This list is the table of the ticket. The window turns off
    /// every action but those two, so an item that AppKit adds later is off too.
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

    /// What the menu draws for each AppKit item when the window is its target, as AppKit sets it for these items. A menu that
    /// updates asks the window `validateMenuItem`. The menu bar of a background run cannot show this: with no key window it
    /// draws every item that has no target as off, whatever the window answers.
    static func appKitItemStates(_ host: AppHost) -> [String: Bool] {
        let menu = NSMenu(title: "AppKit items")
        for item in appKitItems {
            let menuItem = NSMenuItem(title: item.title, action: item.action, keyEquivalent: "")
            menuItem.target = host.window
            menu.addItem(menuItem)
        }
        menu.update()
        return Dictionary(uniqueKeysWithValues: zip(appKitItems, menu.items).map { ($0.title, $1.isEnabled) })
    }

    /// With no sheet, the window answers on for Hide Toolbar, Zoom, Close Window, Minimize and the Window list, so the check
    /// under a sheet tests something. It returns the answers, to compare after the sheet, and logs them.
    static func expectAppKitItemsOn(_ host: AppHost) throws -> [String: Bool] {
        let states = appKitItemStates(host)
        for title in ["Hide Toolbar", "Zoom", "Close Window", "Minimize Window", "Window list"] where states[title] != true {
            throw DriverFailure("\(title) is off with no sheet")
        }
        Log.line("AppKit items with no sheet: " + appKitItems.map { "\($0.title) \(states[$0.title] == true ? "on" : "off")" }.joined(separator: ", "))
        return states
    }

    /// Logs the items of the menu bar that have no command of Loam: the items that AppKit adds, and the items of the app.
    static func logMenuItemsWithNoCommand() {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            submenu.update()
            let plain = submenu.items.filter { !$0.isSeparatorItem && $0.representedObject == nil }.map {
                "\($0.title) (\($0.action.map(NSStringFromSelector) ?? "no action"), \($0.isEnabled ? "on" : "off")\($0.isHidden ? ", hidden" : ""))"
            }
            Log.line("menu \(submenu.title): items with no command of Loam: \(plain.isEmpty ? "none" : plain.joined(separator: "; "))")
        }
    }

    /// A sheet shows over the window, a sheet of Loam or a native one: the window draws off each AppKit item that macOS turns
    /// off under a native sheet, and leaves the others as they were (`baseline`, or on).
    static func expectAppKitItemsOff(_ host: AppHost, baseline: [String: Bool]? = nil) throws {
        let states = appKitItemStates(host)
        for item in appKitItems {
            if item.offUnderSheet {
                if states[item.title] != false { throw DriverFailure("\(item.title) is on under the sheet") }
            } else if states[item.title] != (baseline?[item.title] ?? true) {
                throw DriverFailure("\(item.title) changed under the sheet")
            }
        }
    }

    /// The sheet is closed: each AppKit item draws as it did before the sheet.
    static func expectAppKitItemsBack(_ host: AppHost, baseline: [String: Bool]) throws {
        let states = appKitItemStates(host)
        for item in appKitItems where states[item.title] != baseline[item.title] {
            throw DriverFailure("\(item.title) is \(states[item.title] == true ? "on" : "off") after the sheet, and it was \(baseline[item.title] == true ? "on" : "off") before")
        }
    }

    /// A sheet is open over the window of `plot`: the Land sheet, the New worktree sheet, or a native sheet. Every menu item
    /// that acts on the window draws off. Its key through the menu, its key through the window, its action sent by hand and
    /// the command of a Ghostty key change nothing: no tab, no panel, no sidebar, no overlay, and the sheet stays open. The
    /// caller closes the sheet.
    static func expectKeysOffUnderSheet(_ app: DriverApp, _ host: AppHost, plot: String) async throws {
        let model = host.model
        guard model.sheetIsOpen || host.window.attachedSheet != nil else { throw DriverFailure("no sheet is open") }
        try expectWindowItems(enabled: false)
        try expectAppKitItemsOff(host)

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
