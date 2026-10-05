import AppKit
import LoamKit

/// The window side of the quick switcher: showing the overlay and listing and running menu commands.
extension MainWindowController {
    func connectSwitcher() {
        model.switcher.actions = { [weak self] in self?.menuActions() ?? [] }
        model.switcher.runAction = { [weak self] id in self?.runMenuAction(id) }
        model.switcher.onOpenChange = { [weak self] open in self?.switcherChanged(open: open) }
    }

    private func switcherChanged(open: Bool) {
        if open { closeActionsMenu() }  // One overlay at a time: the actions menu would take the clicks.
        switcherHost.isHidden = !open
        if open {
            window?.makeFirstResponder(switcherHost)
        } else {
            focusActivePane()
        }
    }

    /// Gives the keyboard back to the focused pane of the active plot.
    func focusActivePane() {
        let workspace = model.workspace
        guard let plot = workspace.activePlotID, let focused = workspace.selectedTab(of: plot)?.focused,
              let container = paneArea.container(for: focused) else { return }
        window?.makeFirstResponder(container.focusTarget)
    }

    // MARK: Menu commands

    /// Commands the switcher does not list: its own two items, and the numbered items
    /// (Plot 1 to 9, Tab 1 to 9), which plots and panes already cover.
    private func isListed(_ item: NSMenuItem) -> Bool {
        guard !item.isSeparatorItem, item.submenu == nil, item.action != nil else { return false }
        guard let command = (item.representedObject as? MenuCommand)?.command else { return true }
        switch command {
        case .quickSwitcher, .quickSwitcherActions, .actionsMenu, .selectPlot, .selectTab: return false
        default: return true
        }
    }

    private func menuItems() -> [(id: String, item: NSMenuItem)] {
        var found: [(id: String, item: NSMenuItem)] = []
        for top in NSApp.mainMenu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            for item in submenu.items where isListed(item) {
                found.append((id: "\(submenu.title)/\(item.title)", item: item))
            }
        }
        return found
    }

    func menuActions() -> [SwitcherAction] {
        // A disabled item is not listed, as in the menu bar and the actions menu.
        menuItems().filter { validateMenuItem($0.item) }.map { SwitcherAction(id: $0.id, title: $0.item.title, shortcut: Self.shortcutText($0.item)) }
    }

    func runMenuAction(_ id: String) {
        guard let item = menuItems().first(where: { $0.id == id })?.item, let menu = item.menu else { return }
        menu.performActionForItem(at: menu.index(of: item))
    }

    /// "⌘⇧D" for a menu item, or an empty string.
    static func shortcutText(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let mask = item.keyEquivalentModifierMask
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        return text + item.keyEquivalent.uppercased()
    }
}
