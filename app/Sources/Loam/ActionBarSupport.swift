import AppKit
import LoamKit
import SwiftUI

/// The window side of the action bar and the actions menu (ticket 89). The menu lists commands of
/// the menu bar: their keys come from the menu items, and a disabled item is not listed.
extension MainWindowController: NSMenuItemValidation {
    func installActionBar() {
        let bar = NSHostingView(rootView: ActionBarView(
            bar: actionBar, review: model.review, app: model,
            newSessionKeys: { [weak self] in ActionMenu.keycaps(self?.menuChord(for: .newTab)) },
            actionsKeys: { [weak self] in ActionMenu.keycaps(self?.menuChord(for: .actionsMenu)) },
            newSession: { [weak self] in self?.perform(.newTab) },
            toggleActions: { [weak self] in self?.toggleActionsMenu() }))
        bar.sizingOptions = []
        let menu = NSHostingView(rootView: ActionsMenuView(
            menu: actionBar.menu,
            run: { [weak self] command in self?.runAction(command) },
            close: { [weak self] in self?.closeActionsMenu() }))
        menu.sizingOptions = []
        menu.isHidden = true
        setActionHosts(bar: bar, menu: menu)
        columnBottomInset(ActionBarView.height)
    }

    /// ⌘J or a click on Actions: opens the menu with the actions that can run now, or closes it.
    func toggleActionsMenu() {
        if actionBar.menu.isOpen { return closeActionsMenu() }
        if model.switcher.isOpen { model.switcher.close() }
        let workspace = model.workspace
        let plot = workspace.activePlotID
        let pane = plot.flatMap { workspace.selectedTab(of: $0) }?.focused
        let sections = ActionMenu.sections(
            paneTitle: pane.map { workspace.title(of: $0, terminalTitles: model.terminalTitles) },
            plotName: model.plots.first { $0.id == plot }?.name,
            chord: { [weak self] in self?.menuChord(for: $0) },
            isEnabled: { [weak self] in self?.isEnabled($0) ?? false })
        actionBar.menu.open(sections)
        actionsContext = ActionsContext(plot: plot, pane: pane)
        actionsHost.isHidden = false
        window?.makeFirstResponder(actionsHost)
    }

    /// The rows name the pane and the plot that were focused when the menu opened. When the focus
    /// moves (⌘2, a new session, a click in the sidebar), the menu closes, so no row acts on another
    /// pane or plot than it names.
    func closeActionsMenuIfContextChanged() {
        guard actionBar.menu.isOpen else { return }
        let workspace = model.workspace
        let plot = workspace.activePlotID
        let pane = plot.flatMap { workspace.selectedTab(of: $0) }?.focused
        if actionsContext != ActionsContext(plot: plot, pane: pane) { closeActionsMenu() }
    }

    func closeActionsMenu() {
        guard actionBar.menu.isOpen || !actionsHost.isHidden else { return }
        actionBar.menu.close()
        actionsHost.isHidden = true
        focusActivePane()
    }

    /// Return or a click on a row. The menu has closed already.
    private func runAction(_ command: AppCommand) {
        actionsHost.isHidden = true
        focusActivePane()
        perform(command)
    }

    // MARK: The menu bar as the source

    /// The menu bar item of a command.
    private func menuItem(for command: AppCommand) -> NSMenuItem? {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let submenu = item.submenu, let found = find(submenu) { return found }
                if (item.representedObject as? MenuCommand)?.command == command { return item }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }

    /// The key of a command as the menu bar shows it: a fixed Loam key, or the Ghostty binding
    /// that `applyGhosttyShortcuts` set.
    func menuChord(for command: AppCommand) -> KeyChord? {
        guard let item = menuItem(for: command) else { return LoamKeys.chord(for: command) }
        guard let character = item.keyEquivalent.unicodeScalars.first else { return nil }
        let arrows: [Int: String] = [
            NSUpArrowFunctionKey: "arrow_up", NSDownArrowFunctionKey: "arrow_down",
            NSLeftArrowFunctionKey: "arrow_left", NSRightArrowFunctionKey: "arrow_right",
        ]
        let key = arrows[Int(character.value)] ?? item.keyEquivalent
        let mask = item.keyEquivalentModifierMask
        var mods: KeyChord.Mods = []
        if mask.contains(.control) { mods.insert(.control) }
        if mask.contains(.option) { mods.insert(.option) }
        if mask.contains(.shift) { mods.insert(.shift) }
        if mask.contains(.command) { mods.insert(.command) }
        return KeyChord(mods, key)
    }

    /// Whether a command can run from the actions menu: its rule, and its menu item is enabled.
    private func isEnabled(_ command: AppCommand) -> Bool {
        availability(command) && (menuItem(for: command).map(validateMenuItem) ?? true)
    }

    private func availability(_ command: AppCommand) -> Bool {
        let workspace = model.workspace
        let plot = workspace.activePlotID
        let pane = plot.flatMap { workspace.selectedTab(of: $0) }?.focused
        return ActionMenu.isAvailable(command, hasPlot: plot != nil, hasPane: pane != nil)
    }

    /// The menu bar and the actions menu agree on what can run (`ActionMenu.isAvailable`).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = (menuItem.representedObject as? MenuCommand)?.command else { return true }
        // ⌘W with no pane closes the window (`closePane`), so the menu bar keeps it enabled.
        if command == .closePane { return true }
        return availability(command)
    }
}

/// The focus that an open actions menu was built for.
struct ActionsContext: Equatable {
    var plot: String?
    var pane: PaneID?
}

extension LoamSplitView {
    /// Adds the action bar, the quick switcher and the actions menu overlay over the split view, in
    /// its superview. The split view lays them out with its items (`layout`).
    func install(bar: NSView, overlay: NSView, switcher: NSView, barHeight: CGFloat) {
        self.bar = bar
        self.overlay = overlay
        self.switcher = switcher
        self.barHeight = barHeight
        superview?.addSubview(bar, positioned: .above, relativeTo: self)
        superview?.addSubview(switcher, positioned: .above, relativeTo: bar)
        superview?.addSubview(overlay, positioned: .above, relativeTo: switcher)
        needsLayout = true
    }
}
