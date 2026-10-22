import Foundation

/// A pane that is saved in `state.json` and has not resumed yet. Ticket 29 supplies these.
public struct SavedPane: Equatable, Sendable {
    /// The pane ID as text. Use the same ID when the pane resumes, so its use time carries over.
    public var id: String
    public var plotID: String
    public var title: String
    public var attention: PaneAttention

    public init(id: String, plotID: String, title: String, attention: PaneAttention = .none) {
        self.id = id
        self.plotID = plotID
        self.title = title
        self.attention = attention
    }
}

/// A menu command of the app. The window builds these from the main menu.
public struct SwitcherAction: Equatable, Sendable {
    public var id: String
    public var title: String
    /// The key of the menu item, such as "⌘⇧D". Empty when it has none.
    public var shortcut: String

    public init(id: String, title: String, shortcut: String = "") {
        self.id = id
        self.title = title
        self.shortcut = shortcut
    }
}

/// A link of a plot, as the switcher lists it.
public struct SwitcherLink: Equatable, Sendable {
    public var plotID: String
    public var linkID: String
    public var label: String
    public var target: String
    public var kind: LinkKind

    public init(plotID: String, linkID: String, label: String, target: String, kind: LinkKind = .url) {
        self.plotID = plotID
        self.linkID = linkID
        self.label = label
        self.target = target
        self.kind = kind
    }

    /// The link as the panel holds it, for Start work…. The switcher does not read the note or the version.
    var plotLink: PlotLink {
        PlotLink(id: linkID, label: label, target: target, note: "", position: 0, version: 0, kind: kind, exists: nil)
    }
}

/// One row of the switcher.
public struct SwitcherItem: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case plot, pane, worktree, link, action

        public var label: String { rawValue.uppercased() }

        /// The heading of the kind's section in the list.
        public var heading: String {
            switch self {
            case .plot: "Plots"
            case .pane: "Panes"
            case .worktree: "Worktrees"
            case .link: "Links"
            case .action: "Actions"
            }
        }

        /// The icon of an item of this kind when the item names none.
        var icon: LoamIcon {
            switch self {
            case .plot: .plot
            case .pane: .shell
            case .worktree: .symbol("arrow.triangle.pull")
            case .link: .symbol("link")
            case .action: .action
            }
        }
    }

    public enum Target: Equatable, Sendable {
        /// Home (ticket 99). It is a `.plot` kind item, so it lists with the plots.
        case home
        case plot(String)
        case pane(PaneID)
        case savedPane(SavedPane)
        /// A worktree with a PR (ticket 109), by its ID.
        case worktree(String)
        case link(plot: String, link: String)
        case action(String)
    }

    /// Also the key of the item's use time in `state.json`.
    public var id: String
    public var kind: Kind
    /// The name on the row, and the first match text.
    public var title: String
    /// Match text after the title: a pane's plot name, a link's target and plot name.
    public var otherText: [String]
    /// The plot name shown on the row. Nil for a plot and an action.
    public var plotName: String?
    public var shortcut: String
    public var attention: PaneAttention
    public var target: Target
    /// A Claude mark for a session pane, a service mark or symbol for a link, else the kind's symbol.
    public var icon: LoamIcon
    /// The kind and target of a link item. Nil for the other kinds.
    public var linkKind: LinkKind?
    public var linkTarget: String?
    /// The second action of the item, on ⌘Return (ticket 115). The footer lists it beside the first. Nil for an item that has
    /// only one, and ⌘Return then does nothing.
    public var alternate: Alternate?

    /// What ⌘Return does. A kind that gets a second action adds a case to `Action` and builds the item with it.
    public struct Alternate: Equatable, Sendable {
        public enum Action: Equatable, Sendable {
            /// Start work… on the issue link: the New worktree sheet, filled from the link.
            case startWork(SwitcherLink)
        }
        public var title: String
        public var action: Action

        public init(title: String, action: Action) {
            self.title = title
            self.action = action
        }
    }

    public init(id: String, kind: Kind, title: String, otherText: [String] = [], plotName: String? = nil,
                shortcut: String = "", attention: PaneAttention = .none, target: Target, icon: LoamIcon? = nil,
                linkKind: LinkKind? = nil, linkTarget: String? = nil, alternate: Alternate? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.otherText = otherText
        self.plotName = plotName
        self.shortcut = shortcut
        self.attention = attention
        self.target = target
        self.icon = icon ?? kind.icon
        self.linkKind = linkKind
        self.linkTarget = linkTarget
        self.alternate = alternate
    }

    /// The kind in words, on the right of the row: "Home", "Plot", "Pane", "Worktree", "Local link", "Action".
    public var accessory: String {
        switch kind {
        case .plot: target == .home ? Space.homeName : "Plot"
        case .pane: "Pane"
        case .worktree: "Worktree"
        case .action: "Action"
        case .link: SwitcherItem.linkKindLabel(linkKind)
        }
    }

    public static func linkKindLabel(_ kind: LinkKind?) -> String {
        switch kind {
        case .notion: "Notion link"
        case .linear: "Linear link"
        case .github: "GitHub link"
        case .url: "Web link"
        case .path: "Local link"
        case .vault: "Vault link"
        case nil: "Link"
        }
    }

    public static func plotKey(_ id: String) -> String { "plot:\(id)" }
    public static let homeKey = "home"
    /// The use time key of a space.
    public static func key(of space: Space) -> String {
        switch space {
        case .home: homeKey
        case .plot(let id): plotKey(id)
        }
    }
    public static func paneKey(_ id: String) -> String { "pane:\(id)" }
    public static func linkKey(plot: String, link: String) -> String { "link:\(plot):\(link)" }
    public static func worktreeKey(_ id: String) -> String { "worktree:\(id)" }
}

/// An item that matched, with the characters of its title to highlight.
public struct SwitcherResult: Equatable, Sendable, Identifiable {
    public var item: SwitcherItem
    public var score: Int
    public var titleMatches: Set<Int>
    public var id: String { item.id }
}
