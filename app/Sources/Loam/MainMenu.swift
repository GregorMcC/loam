import AppKit
import LoamKit

/// A menu item's command. Items for Ghostty actions also carry the action name, so their key
/// follows your Ghostty config.
final class MenuCommand: NSObject {
    let command: AppCommand
    let ghosttyAction: String?
    init(_ command: AppCommand, ghosttyAction: String?) {
        self.command = command
        self.ghosttyAction = ghosttyAction
    }
}

/// The main menu. Loam's fixed keys (spec 8.3) come from `LoamKeys.fixed`. Items for Ghostty's
/// actions show the key that your Ghostty config binds: `applyGhosttyShortcuts` sets them after
/// each config load.
@MainActor
func makeMainMenu(target: MainWindowController) -> NSMenu {
    let main = NSMenu()

    func item(_ menu: NSMenu, _ title: String, _ command: AppCommand, ghostty action: String? = nil) {
        let item = NSMenuItem(title: title, action: #selector(MainWindowController.performCommand(_:)), keyEquivalent: "")
        item.representedObject = MenuCommand(command, ghosttyAction: action)
        item.target = target
        if action == nil, let chord = LoamKeys.chord(for: command) { item.setShortcut(chord) }
        menu.addItem(item)
    }

    func ghostty(_ menu: NSMenu, _ title: String, _ action: String) {
        guard let command = LoamKeys.ghosttyMenuActions.first(where: { $0.action == action })?.command else { return }
        item(menu, title, command, ghostty: action)
    }

    func submenu(_ title: String) -> NSMenu {
        let item = NSMenuItem()
        main.addItem(item)
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }

    let app = submenu("Loam")
    item(app, "Settings\u{2026}", .openSettings)
    app.addItem(.separator())
    ghostty(app, "Open Ghostty Config", "open_config")
    ghostty(app, "Reload Ghostty Config", "reload_config")
    app.addItem(.separator())
    app.addItem(withTitle: "Quit Loam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let file = submenu("File")
    item(file, "New Plot\u{2026}", .newPlot)
    ghostty(file, "New Tab", "new_tab")
    item(file, "New Shell Tab", .newShellTab)
    ghostty(file, "Split Right", "new_split:right")
    ghostty(file, "Split Down", "new_split:down")
    item(file, "Split Right with Shell", .newShellSplit(.sideBySide))
    item(file, "Split Down with Shell", .newShellSplit(.stacked))
    file.addItem(.separator())
    ghostty(file, "Close", "close_surface")

    // Nil targets: the focused pane handles these.
    let edit = submenu("Edit")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    let view = submenu("View")
    item(view, "Toggle Sidebar", .toggleSidebar)
    item(view, "Plot Panel", .togglePlotPanel)

    let go = submenu("Go")
    item(go, "Quick Switcher", .quickSwitcher)
    item(go, "Quick Switcher: Actions", .quickSwitcherActions)
    item(go, "Actions", .actionsMenu)
    go.addItem(.separator())
    item(go, "Next Pane That Needs You", .nextPaneThatNeedsYou)

    let plots = submenu("Plot")
    // The plot's own actions (ticket 89). The actions menu (⌘J) lists them from here.
    item(plots, "New Session in Plot", .newPlotSession)
    item(plots, "Edit Brief", .editBrief)
    item(plots, "Add Link\u{2026}", .addLink)
    item(plots, "Add Repo\u{2026}", .addRepo)
    item(plots, "Archive Plot\u{2026}", .archivePlot)
    plots.addItem(.separator())
    for n in 1...9 { item(plots, "Plot \(n)", .selectPlot(n)) }

    let tabs = submenu("Tab")
    ghostty(tabs, "Next Tab", "next_tab")
    ghostty(tabs, "Previous Tab", "previous_tab")
    ghostty(tabs, "Next Split", "goto_split:next")
    ghostty(tabs, "Previous Split", "goto_split:previous")
    tabs.addItem(.separator())
    for n in 1...8 { ghostty(tabs, "Tab \(n)", "goto_tab:\(n)") }
    ghostty(tabs, "Last Tab", "last_tab")

    let window = submenu("Window")
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

    applyGhosttyShortcuts(to: main, chord: LoamKeys.defaultChord(forGhosttyAction:))
    return main
}

/// Sets the key of each Ghostty action item from your config. A key that Loam owns never shows
/// on a Ghostty item, and an action with no key shows none.
@MainActor
func applyGhosttyShortcuts(to menu: NSMenu, chord: (String) -> KeyChord?) {
    for item in menu.items {
        if let submenu = item.submenu { applyGhosttyShortcuts(to: submenu, chord: chord) }
        guard let action = (item.representedObject as? MenuCommand)?.ghosttyAction else { continue }
        if let shortcut = LoamKeys.menuChord(forGhosttyBinding: chord(action)) {
            item.setShortcut(shortcut)
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }
}

extension NSMenuItem {
    func setShortcut(_ chord: KeyChord) {
        let arrows: [String: Int] = [
            "arrow_up": NSUpArrowFunctionKey, "arrow_down": NSDownArrowFunctionKey,
            "arrow_left": NSLeftArrowFunctionKey, "arrow_right": NSRightArrowFunctionKey,
        ]
        if let arrow = arrows[chord.key], let scalar = UnicodeScalar(arrow) {
            keyEquivalent = String(Character(scalar))
        } else if chord.key.count == 1 {
            keyEquivalent = chord.key
        } else {
            keyEquivalent = ""
            keyEquivalentModifierMask = []
            return
        }
        var mask: NSEvent.ModifierFlags = []
        if chord.mods.contains(.command) { mask.insert(.command) }
        if chord.mods.contains(.shift) { mask.insert(.shift) }
        if chord.mods.contains(.option) { mask.insert(.option) }
        if chord.mods.contains(.control) { mask.insert(.control) }
        keyEquivalentModifierMask = mask
    }
}
