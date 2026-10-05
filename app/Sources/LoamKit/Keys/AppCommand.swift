import Foundation

/// One thing the app can do from a key, a menu item, or a Ghostty action (spec 8.3).
/// The window runs it on the active plot.
public enum AppCommand: Hashable, Sendable {
    // Loam's own keys, fixed in v1.
    case quickSwitcher
    case quickSwitcherActions
    /// ⌘J: the actions menu of the bottom bar (ticket 89).
    case actionsMenu
    case nextPaneThatNeedsYou
    case selectPlot(Int)
    case newPlot
    case toggleSidebar
    case togglePlotPanel
    case newShellTab
    /// ⌘, opens the settings window (ticket 81).
    case openSettings
    /// A shell split has no key. It comes from the menu or the switcher.
    case newShellSplit(SplitAxis)

    // Ghostty's tab and split actions, on the active plot.
    case newTab
    case newSplit(SplitAxis)
    case focusPane(PaneStep)
    /// 1 to 8 select that tab. 9 and up select the last tab, as ⌘9 does.
    case selectTab(Int)
    case previousTab
    case nextTab
    case lastTab
    case closePane
    case closeTab
    case equalizeSplits
    /// Ghostty gives the amount in points. The window turns it into a fraction of the pane area.
    case resizeSplit(SplitTree.ResizeDirection, points: Double)
    case undo
    case redo

    // The Ghostty config.
    case openConfig
    case reloadConfig

    case quit

    // The plot's own actions (ticket 89), in the Plot menu and the actions menu.
    /// A session in the plot folder, not in a repo (ticket 93).
    case newPlotSession
    case editBrief
    case addLink
    case addRepo
    case archivePlot

    /// A focus move between the panes of the selected tab.
    public enum PaneStep: Hashable, Sendable {
        case previous, next, up, down, left, right
    }
}

/// A Loam key that no Ghostty config can change.
public struct FixedKey: Hashable, Sendable {
    public let chord: KeyChord
    public let command: AppCommand
    /// The name of the command, for menus and the clash log.
    public let title: String
    /// The Ghostty action that this key stands for (spec 8.3), if any. A Ghostty binding of the
    /// key to this action is no clash: it means the same thing.
    public let ghosttyAction: String?

    public init(_ chord: KeyChord, _ command: AppCommand, _ title: String, ghosttyAction: String? = nil) {
        self.chord = chord
        self.command = command
        self.title = title
        self.ghosttyAction = ghosttyAction
    }
}

/// Loam's own keys (spec 8.3) and how a key event finds its way.
public enum LoamKeys {
    /// Loam's own keys, fixed in v1. They win over a binding of the same key in your Ghostty config.
    public static let fixed: [FixedKey] = [
        FixedKey(KeyChord(.command, "p"), .quickSwitcher, "Quick Switcher"),
        FixedKey(KeyChord([.command, .shift], "p"), .quickSwitcherActions, "Quick Switcher Actions",
                 ghosttyAction: "toggle_command_palette"),
        FixedKey(KeyChord(.command, "l"), .nextPaneThatNeedsYou, "Next Pane That Needs You"),
        // ⌘K stays Ghostty's clear screen, so the actions menu takes ⌘J (ticket 89).
        FixedKey(KeyChord(.command, "j"), .actionsMenu, "Actions"),
        FixedKey(KeyChord(.command, "n"), .newPlot, "New Plot", ghosttyAction: "new_window"),
        FixedKey(KeyChord(.command, "b"), .toggleSidebar, "Toggle Sidebar"),
        FixedKey(KeyChord(.command, "i"), .togglePlotPanel, "Plot Panel"),
        FixedKey(KeyChord([.command, .option], "t"), .newShellTab, "New Shell Tab"),
        // Ghostty binds ⌘, to open_config. Loam's Settings wins, so Open Ghostty Config shows no key.
        FixedKey(KeyChord(.command, ","), .openSettings, "Settings"),
    ] + (1...9).map { FixedKey(KeyChord(.control, "\($0)"), .selectPlot($0), "Plot \($0)") }

    private static let byChord = Dictionary(uniqueKeysWithValues: fixed.map { ($0.chord, $0) })

    /// The fixed key for a chord, if Loam owns it.
    public static func fixedKey(for chord: KeyChord) -> FixedKey? { byChord[chord] }

    /// The chord of a fixed command, for its menu item.
    public static func chord(for command: AppCommand) -> KeyChord? {
        fixed.first { $0.command == command }?.chord
    }

    /// Where a key that reaches a focused pane goes.
    public enum Route: Equatable, Sendable {
        /// A fixed Loam key. Loam runs the command, and libghostty never sees the key.
        case loam(AppCommand)
        /// A Ghostty binding. The main menu goes first, so a menu key runs the same handler with
        /// the same key, then libghostty runs it and sends the action to Loam.
        case menuThenTerminal
        /// Any other key goes to the terminal.
        case terminal
    }

    public static func route(_ chord: KeyChord, isGhosttyBinding: Bool) -> Route {
        if let fixed = fixedKey(for: chord) { return .loam(fixed.command) }
        return isGhosttyBinding ? .menuThenTerminal : .terminal
    }

    /// A Ghostty action with a Loam menu item.
    public struct GhosttyMenuAction: Sendable {
        /// The action name in a Ghostty config, such as "new_tab".
        public let action: String
        public let command: AppCommand
        /// Ghostty's default macOS key, for a build with no libghostty.
        public let defaultChord: KeyChord
    }

    /// The Ghostty actions that have a Loam menu item. The menu shows the key that your Ghostty
    /// config binds to each action, so a rebind shows in the menu too.
    public static let ghosttyMenuActions: [GhosttyMenuAction] = [
        GhosttyMenuAction(action: "new_tab", command: .newTab, defaultChord: KeyChord(.command, "t")),
        GhosttyMenuAction(action: "new_split:right", command: .newSplit(.sideBySide), defaultChord: KeyChord(.command, "d")),
        GhosttyMenuAction(action: "new_split:down", command: .newSplit(.stacked), defaultChord: KeyChord([.command, .shift], "d")),
        GhosttyMenuAction(action: "close_surface", command: .closePane, defaultChord: KeyChord(.command, "w")),
        GhosttyMenuAction(action: "previous_tab", command: .previousTab, defaultChord: KeyChord([.command, .shift], "[")),
        GhosttyMenuAction(action: "next_tab", command: .nextTab, defaultChord: KeyChord([.command, .shift], "]")),
        GhosttyMenuAction(action: "goto_split:previous", command: .focusPane(.previous), defaultChord: KeyChord(.command, "[")),
        GhosttyMenuAction(action: "goto_split:next", command: .focusPane(.next), defaultChord: KeyChord(.command, "]")),
    ] + (1...8).map {
        GhosttyMenuAction(action: "goto_tab:\($0)", command: .selectTab($0), defaultChord: KeyChord(.command, "\($0)"))
    } + [
        GhosttyMenuAction(action: "last_tab", command: .lastTab, defaultChord: KeyChord(.command, "9")),
        GhosttyMenuAction(action: "open_config", command: .openConfig, defaultChord: KeyChord(.command, ",")),
        GhosttyMenuAction(action: "reload_config", command: .reloadConfig, defaultChord: KeyChord([.command, .shift], ",")),
    ]

    /// Ghostty's default key for a menu action.
    public static func defaultChord(forGhosttyAction action: String) -> KeyChord? {
        ghosttyMenuActions.first { $0.action == action }?.defaultChord
    }

    /// The key a menu item shows for a Ghostty action. A key that Loam owns never shows on a
    /// Ghostty item, because Loam's key wins.
    public static func menuChord(forGhosttyBinding chord: KeyChord?) -> KeyChord? {
        guard let chord, fixedKey(for: chord) == nil else { return nil }
        return chord
    }
}
