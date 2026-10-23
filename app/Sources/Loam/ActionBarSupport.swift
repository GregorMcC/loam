import AppKit
import LoamKit
import SwiftUI

/// The window side of the action bar and the actions menu (ticket 89). The menu lists commands of
/// the menu bar: their keys come from the menu items, and a disabled item is not listed.
extension MainWindowController: NSMenuItemValidation {
    func installActionBar() {
        let bar = NSHostingView(rootView: ActionBarView(
            bar: actionBar, review: model.review, app: model, chipProbe: chipProbe,
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
        let popover = NSHostingView(rootView: PRPopoverView(
            app: model, place: popoverPlace, runPrimary: { [weak self] in self?.runPrimaryAction($0) }))
        popover.sizingOptions = []
        popover.isHidden = true
        let sheet = NSHostingView(rootView: LandSheetView(app: model))
        sheet.sizingOptions = []
        sheet.isHidden = true
        setActionHosts(bar: bar, menu: menu, popover: popover, sheet: sheet)
        installNewWorktreeSheet()
        installTitleBarScrim()
        model.landSheet.onOpenChange = { [weak self] open in self?.landSheetChanged(open: open) }
        model.confirmClose = { [weak self] prompt in await self?.askClose(prompt) ?? false }
        model.paneClosesFinished = { [weak self] in await self?.waitForPaneCloses() }
        model.onOwnChange = { [actionBar] in actionBar.ignoreChange($0) }
        model.prPopover.onOpenChange = { [weak self] open in self?.pullRequestPopoverChanged(open: open) }
        model.prPopover.onOpen = { [weak self] in self?.placePullRequestPopover() }
        // Send to session (ticket 110): the toast after Loam typed a prompt, and the keys for the session.
        model.onToast = { [weak self] in self?.actionBar.show($0, kind: $1) }
        model.onPromptTyped = { [weak self] _ in self?.focusActivePane() }
        model.copyText = SystemActions.copy
        columnBottomInset(ActionBarView.height)
    }

    /// ⌘J or a click on Actions: opens the menu with the actions that can run now, or closes it.
    func toggleActionsMenu() {
        if actionBar.menu.isOpen { return closeActionsMenu() }
        // A merge or a worktree start keeps its sheet (`sheetHoldsWindow`). The menu stays shut then, since it would show
        // over the sheet and its commands would change the window under it.
        if model.sheetHoldsWindow { return }
        if model.switcher.isOpen { model.switcher.close() }
        model.closePullRequest()  // One overlay at a time: the popover would take the clicks of the menu.
        model.closeLandSheet()
        model.closeNewWorktree()
        let workspace = model.workspace
        let space = workspace.activeSpace
        let pane = workspace.focusedPane
        let sections = ActionMenu.sections(
            paneTitle: pane.map { workspace.title(of: $0, terminalTitles: model.terminalTitles) },
            plotName: workspace.activePlotID.flatMap { model.name(of: .plot($0)) },
            worktree: model.focusedWorktree.map { ActionMenu.WorktreeFacts(branch: $0.branch) },
            inHome: space == .home,
            moveTargets: space == .home ? model.moveTargets : [],
            chord: { [weak self] in self?.menuChord(for: $0) },
            isEnabled: { [weak self] in self?.isEnabled($0) ?? false })
        actionBar.menu.open(sections)
        actionsContext = ActionsContext(space: space, pane: pane)
        actionsHost.isHidden = false
        window?.makeFirstResponder(actionsHost)
    }

    /// The rows name the pane and the space that were focused when the menu opened. When the focus
    /// moves (⌘2, a new session, a click in the sidebar), the menu closes, so no row acts on another
    /// pane or space than it names.
    func closeActionsMenuIfContextChanged() {
        guard actionBar.menu.isOpen else { return }
        let workspace = model.workspace
        if actionsContext != ActionsContext(space: workspace.activeSpace, pane: workspace.focusedPane) { closeActionsMenu() }
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
        let worktree = model.focusedWorktree.flatMap { model.worktreeStatus($0.id) }
        return ActionMenu.isAvailable(command, hasSpace: workspace.activeSpace != nil, hasPlot: workspace.activePlotID != nil,
                                      hasPane: workspace.focusedPane != nil, hasWorktree: worktree != nil,
                                      hasPullRequest: worktree?.pr != nil,
                                      checksFailed: worktree.map { model.canSendFailures($0.worktree.id) } ?? false,
                                      readyToMerge: worktree?.stage == .readyToMerge)
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
    var space: Space?
    var pane: PaneID?
}

extension LoamSplitView {
    /// Adds the action bar, the PR popover, the Land sheet, the quick switcher and the actions menu overlay over the
    /// split view, in its superview. The split view lays them out with its items (`layout`).
    func install(bar: NSView, overlay: NSView, popover: NSView, sheet: NSView, switcher: NSView, barHeight: CGFloat) {
        self.bar = bar
        self.overlay = overlay
        self.popover = popover
        self.sheet = sheet
        self.switcher = switcher
        self.barHeight = barHeight
        superview?.addSubview(bar, positioned: .above, relativeTo: self)
        superview?.addSubview(popover, positioned: .above, relativeTo: bar)
        superview?.addSubview(sheet, positioned: .above, relativeTo: popover)
        superview?.addSubview(switcher, positioned: .above, relativeTo: sheet)
        superview?.addSubview(overlay, positioned: .above, relativeTo: switcher)
        needsLayout = true
    }
}
