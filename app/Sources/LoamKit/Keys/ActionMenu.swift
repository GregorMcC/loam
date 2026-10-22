import Foundation
import Observation

/// One row of the actions menu (ticket 89): a command of the menu bar, its symbol, its label,
/// and the real keys of that command as keycaps.
public struct ActionItem: Equatable, Sendable, Identifiable {
    public var command: AppCommand
    public var title: String
    /// An SF Symbol name.
    public var symbol: String
    /// One keycap per symbol, such as ["⇧", "⌘", "D"]. Empty for a command with no key.
    public var keys: [String]
    /// The command, not the title: two plots can have the same name.
    public var id: AppCommand { command }
}

/// A section of the actions menu: the focused pane, its worktree, a move to a plot, the active plot, or Home.
public struct ActionSection: Equatable, Sendable, Identifiable {
    /// "pane", "worktree", "move", "plot", or "home". Not the title: a pane and its plot can have the same name.
    public var id: String
    public var title: String
    public var items: [ActionItem]
}

/// The actions of the bottom bar's menu (⌘J). The commands are the ones of the menu bar, and
/// the caller gives their keys and whether they are enabled from the menu bar, so the keycaps are
/// always the real ones and a disabled command is not listed.
public enum ActionMenu {
    struct Entry {
        let command: AppCommand
        let title: String
        let symbol: String
    }

    static let paneEntries = [
        Entry(command: .newTab, title: "New session", symbol: "play"),
        Entry(command: .newSplit(.sideBySide), title: "Split right", symbol: "rectangle.split.2x1"),
        Entry(command: .newSplit(.stacked), title: "Split down", symbol: "rectangle.split.1x2"),
        Entry(command: .newShellSplit(.sideBySide), title: "Split right with shell", symbol: "apple.terminal"),
        Entry(command: .newShellSplit(.stacked), title: "Split down with shell", symbol: "apple.terminal"),
        Entry(command: .closePane, title: "Close pane", symbol: "xmark"),
    ]

    /// The worktree of the focused pane (ticket 109).
    static let worktreeEntries = [
        Entry(command: .showWorktreePullRequest, title: "Show pull request", symbol: "arrow.triangle.pull"),
        Entry(command: .refreshWorktree, title: "Refresh", symbol: "arrow.clockwise"),
    ]

    static let plotEntries = [
        Entry(command: .newPlotSession, title: "New session in plot", symbol: "play"),
        Entry(command: .editBrief, title: "Edit brief", symbol: "pencil"),
        Entry(command: .addLink, title: "Add link", symbol: "link"),
        Entry(command: .addRepo, title: "Add repo", symbol: "arrow.triangle.branch"),
        Entry(command: .archivePlot, title: "Archive plot", symbol: "archivebox"),
    ]

    /// Home (ticket 99): a tab in Home from any plot. In Home itself, ⌘T and ⌘⌥T do the same.
    static let homeEntries = [
        Entry(command: .newHomeSession, title: "New session in Home", symbol: "house"),
        Entry(command: .newHomeShell, title: "New shell in Home", symbol: "apple.terminal"),
    ]

    /// A row for each plot, then "Move to New Plot…".
    static func moveEntries(_ targets: [PlotSummary]) -> [Entry] {
        targets.map { Entry(command: .moveTabToPlot($0.id), title: "Move to \($0.name)", symbol: "arrow.right.square") }
            + [Entry(command: .moveTabToNewPlot, title: "Move to New Plot…", symbol: "plus.square")]
    }

    /// What the actions menu needs to know about the worktree of the focused pane.
    public struct WorktreeFacts: Equatable, Sendable {
        /// The title of the section.
        public var branch: String

        public init(branch: String) {
            self.branch = branch
        }
    }

    /// The sections for the focused pane, its worktree, a move to a plot, the active plot, and Home.
    /// `worktree` is nil for a pane that runs in no worktree, and then the menu has no worktree section.
    /// `chord` gives the key of a command as the menu bar shows it, `isEnabled` whether its menu item is
    /// enabled. `inHome` leaves out the Home section, because its rows would repeat "New session" and ⌘⌥T,
    /// and adds the move of the tab to a plot (ticket 100). `moveTargets` are the plots, in sidebar order.
    public static func sections(paneTitle: String?, plotName: String?, worktree: WorktreeFacts? = nil, inHome: Bool = false,
                                moveTargets: [PlotSummary] = [], chord: (AppCommand) -> KeyChord?,
                                isEnabled: (AppCommand) -> Bool) -> [ActionSection] {
        func items(_ entries: [Entry]) -> [ActionItem] {
            entries.filter { isEnabled($0.command) }.map {
                ActionItem(command: $0.command, title: $0.title, symbol: $0.symbol, keys: keycaps(chord($0.command)))
            }
        }
        return [
            ActionSection(id: "pane", title: paneTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Pane", items: items(paneEntries)),
            ActionSection(id: "worktree", title: worktree?.branch ?? "Worktree", items: worktree == nil ? [] : items(worktreeEntries)),
            ActionSection(id: "move", title: "Move to Plot", items: inHome ? items(moveEntries(moveTargets)) : []),
            ActionSection(id: "plot", title: plotName.flatMap { $0.isEmpty ? nil : $0 } ?? "Plot", items: items(plotEntries)),
            ActionSection(id: "home", title: Space.homeName, items: inHome ? [] : items(homeEntries)),
        ].filter { !$0.items.isEmpty }
    }

    /// Whether a command can run now. The menu bar validates its items with this, so the menu and
    /// the actions list agree. Tab commands need an active space (Home or a plot), pane commands a
    /// focused pane, and plot commands an active plot. A move to a plot needs a tab in Home. The worktree
    /// commands need a focused pane in a worktree (ticket 109), and Show pull request needs a PR as well.
    public static func isAvailable(_ command: AppCommand, hasSpace: Bool, hasPlot: Bool, hasPane: Bool,
                                   hasWorktree: Bool = false, hasPullRequest: Bool = false) -> Bool {
        switch command {
        case .newTab, .newShellTab: hasSpace
        case .newPlotSession, .editBrief, .addLink, .addRepo, .archivePlot, .togglePlotPanel: hasPlot
        case .newSplit, .newShellSplit, .closePane: hasSpace && hasPane
        case .moveTabToPlot, .moveTabToNewPlot: hasSpace && !hasPlot && hasPane
        case .refreshWorktree: hasWorktree
        case .showWorktreePullRequest: hasWorktree && hasPullRequest
        default: true
        }
    }

    /// The rows whose title holds each word of the query, in any case. Empty sections go.
    public static func filter(_ sections: [ActionSection], query: String) -> [ActionSection] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return sections }
        return sections.compactMap { section in
            let items = section.items.filter { item in
                let title = item.title.lowercased()
                return words.allSatisfy { title.contains($0) }
            }
            return items.isEmpty ? nil : ActionSection(id: section.id, title: section.title, items: items)
        }
    }

    /// The keycaps of a chord, in the macOS order: ⌃ ⌥ ⇧ ⌘, then the key.
    public static func keycaps(_ chord: KeyChord?) -> [String] {
        guard let chord else { return [] }
        var caps: [String] = []
        let mods: [(KeyChord.Mods, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        for (mod, symbol) in mods where chord.mods.contains(mod) { caps.append(symbol) }
        let named = ["arrow_up": "↑", "arrow_down": "↓", "arrow_left": "←", "arrow_right": "→",
                     "enter": "↩", "escape": "⎋", "tab": "⇥", "space": "Space"]
        caps.append(named[chord.key] ?? (chord.key.count == 1 ? chord.key.uppercased() : chord.key))
        return caps
    }
}

/// The open actions menu: the query, the rows it leaves, and the selected row.
@MainActor @Observable
public final class ActionMenuModel {
    public private(set) var isOpen = false
    /// The room between the right end of the action bar and the right edge of the window: the
    /// width of the plot panel while it shows. The menu sits over the right end of the bar.
    public var trailingInset: Double = 0
    /// Counts the opens, so the view can focus its field on each one.
    public private(set) var openCount = 0
    /// The text of the search field at the bottom of the menu.
    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            visible = ActionMenu.filter(all, query: query)
            selection = 0
        }
    }
    /// The sections that the query leaves.
    public private(set) var visible: [ActionSection] = []
    /// The index of the selected row in `rows`.
    public private(set) var selection = 0
    private var all: [ActionSection] = []

    public init() {}

    /// The visible rows, top to bottom.
    public var rows: [ActionItem] { visible.flatMap(\.items) }

    public var selected: ActionItem? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    /// Opens the menu with these sections. The first row is selected.
    public func open(_ sections: [ActionSection]) {
        all = sections
        query = ""
        visible = sections
        selection = 0
        isOpen = true
        openCount += 1
    }

    public func close() {
        isOpen = false
        query = ""
    }

    /// Moves the selection by `step` rows. It stops at the first and the last row.
    public func move(_ step: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = min(count - 1, max(0, selection + step))
    }

    public func select(_ item: ActionItem) {
        if let index = rows.firstIndex(of: item) { selection = index }
    }

    /// Return: the command of the selected row, and the menu closes. Nil when no row is left.
    public func runSelected() -> AppCommand? {
        guard let item = selected else { return nil }
        close()
        return item.command
    }
}
