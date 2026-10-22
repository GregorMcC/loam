import Foundation

/// What the preview column of the switcher shows for the selected result (ticket 90). It is a pure
/// function of the item and a `Context`, so tests cover the fields and the captions. The view only draws it.
public struct SwitcherPreview: Equatable, Sendable {
    /// One value of a metadata row.
    public enum Value: Equatable, Sendable {
        case text(String)
        /// A name with a branch chip. The chip is absent when the branch is not known.
        case branch(name: String, branch: String?)
        /// A pane state or a pane name with its mark.
        case attention(PaneAttention, String)
        /// A folder or file, in the mono face.
        case path(String)
        /// Small tag pills.
        case tags([String])
        /// Keycaps, one per key.
        case keys([String])
    }

    public struct Row: Equatable, Sendable {
        public var label: String
        public var value: Value
    }

    public var icon: LoamIcon
    public var title: String
    public var caption: String
    /// The text under "Where it stands". Only a plot has it.
    public var whereItStands: String?
    public var rows: [Row]
    /// The primary action in the footer: "Open plot", "Go to pane", "Show pull request", "Open link", "Run".
    public var footerAction: String
    /// The second action in the footer, on ⌘Return (ticket 115). Nil when the item has none.
    public var alternateAction: String?

    /// The facts about one pane that the preview needs.
    public struct PaneFacts: Equatable, Sendable {
        public var id: String
        public var space: Space
        public var title: String
        public var kind: PaneSpec.Kind?
        public var state: PaneState?
        public var attention: PaneAttention
        public var folder: String?
        public var worktree: WorktreeRef?
        /// True for a pane in `state.json` that has not resumed.
        public var saved: Bool

        public init(id: String, space: Space, title: String, kind: PaneSpec.Kind?, state: PaneState?,
                    attention: PaneAttention, folder: String?, worktree: WorktreeRef?, saved: Bool) {
            self.id = id
            self.space = space
            self.title = title
            self.kind = kind
            self.state = state
            self.attention = attention
            self.folder = folder
            self.worktree = worktree
            self.saved = saved
        }
    }

    /// The model's data. `plots` and `changes` come from one `loam export`, so they are empty until it ends.
    public struct Context {
        public var plots: [String: Plot]
        public var panes: [PaneFacts]
        public var changes: [Change]
        public var checkouts: [String: [RepoCheckout]]
        public var actorText: (Change) -> String
        public var clock: (Change) -> String
        public var home: String
        /// The worktrees of the plots, for a worktree item.
        public var worktrees: [WorktreeStatus]

        public init(plots: [String: Plot], panes: [PaneFacts], changes: [Change], checkouts: [String: [RepoCheckout]],
                    actorText: @escaping (Change) -> String, clock: @escaping (Change) -> String, home: String,
                    worktrees: [WorktreeStatus] = []) {
            self.plots = plots
            self.panes = panes
            self.changes = changes
            self.checkouts = checkouts
            self.actorText = actorText
            self.clock = clock
            self.home = home
            self.worktrees = worktrees
        }

        func panes(of space: Space) -> [PaneFacts] { panes.filter { $0.space == space } }
    }

    // MARK: Row text

    /// The text after the title of a row: the pane count of Home or a plot, else the plot name, or
    /// "Home" for a Home pane. Nil for an action.
    public static func subtitle(for item: SwitcherItem, in context: Context) -> String? {
        switch item.target {
        case .home: count(context.panes(of: .home).count, "pane")
        case .plot(let id): count(context.panes(of: .plot(id)).count, "pane")
        default: item.plotName
        }
    }

    // MARK: Preview

    public static func make(for item: SwitcherItem, in context: Context) -> SwitcherPreview {
        switch item.target {
        case .home: home(item, context)
        case .plot(let id): plot(item, id: id, context)
        case .pane, .savedPane: pane(item, context)
        case .worktree(let id): worktree(item, id: id, context)
        case .link: link(item, context)
        case .action: action(item)
        }
    }

    /// Home has no brief, repos, or links: only its panes.
    private static func home(_ item: SwitcherItem, _ context: Context) -> SwitcherPreview {
        let panes = context.panes(of: .home)
        let rows = (panes.isEmpty ? [] : [Row(label: "Panes", value: .text("\(panes.count)"))]) + attentionRows(panes)
        return SwitcherPreview(icon: item.icon, title: item.title, caption: "Home · \(count(panes.count, "pane"))",
                               whereItStands: nil, rows: rows, footerAction: "Open Home")
    }

    private static func plot(_ item: SwitcherItem, id: String, _ context: Context) -> SwitcherPreview {
        let panes = context.panes(of: .plot(id))
        var caption = ["Plot", count(panes.count, "pane")]
        let detail = context.plots[id]
        if let detail { caption.append(count(detail.links.count, "link")) }
        var rows: [Row] = []
        let checkouts = context.checkouts[id] ?? []
        if let main = checkouts.first(where: \.isMain) {
            rows.append(Row(label: "Main repo", value: .branch(name: main.name, branch: main.branch)))
        } else if let main = detail?.repos.first(where: \.main) {
            rows.append(Row(label: "Main repo", value: .branch(name: folderName(main.path), branch: nil)))
        }
        if detail != nil || !panes.isEmpty { rows.append(Row(label: "Panes", value: .text("\(panes.count)"))) }
        rows += attentionRows(panes)
        if let last = context.changes.filter({ $0.plotID == id }).max(by: { $0.id < $1.id }) {
            let text = "\(context.actorText(last)): \(ChangeRules.summary(last, linkLabels: detail?.linkLabels ?? [:])), \(context.clock(last))"
            rows.append(Row(label: "Last change", value: .text(text)))
        }
        if let detail, !detail.repos.isEmpty {
            let ordered = detail.repos.filter(\.main) + detail.repos.filter { !$0.main }
            rows.append(Row(label: "Repos", value: .tags(ordered.map { folderName($0.path) })))
        }
        return SwitcherPreview(icon: item.icon, title: item.title, caption: caption.joined(separator: " · "),
                               whereItStands: detail?.whereItStands, rows: rows, footerAction: "Open plot")
    }

    /// A "Needs you" row and a "Done, unread" row, each when a pane is in that state.
    private static func attentionRows(_ panes: [PaneFacts]) -> [Row] {
        [(PaneAttention.needsYou, "Needs you"), (.doneUnread, "Done, unread")].compactMap { attention, label in
            let named = panes.filter { $0.attention == attention }
            guard let first = named.first else { return nil }
            let text = named.count == 1 ? first.title : "\(first.title) and \(named.count - 1) more"
            return Row(label: label, value: .attention(attention, text))
        }
    }

    private static func pane(_ item: SwitcherItem, _ context: Context) -> SwitcherPreview {
        let facts = context.panes.first { $0.id == item.id }
        let kind = facts?.kind == .session ? "Claude session" : "Shell"
        var rows: [Row] = []
        // A Home pane has no plot. Its row in the list says "Home".
        if let plot = item.plotName, facts?.space.isHome != true { rows.append(Row(label: "Plot", value: .text(plot))) }
        if let facts {
            if let checkout = checkout(of: facts, context) { rows.append(Row(label: "Checkout", value: checkout)) }
            rows.append(Row(label: "State", value: state(of: facts)))
            if let folder = facts.folder ?? facts.worktree?.path {
                rows.append(Row(label: "Folder", value: .path(abbreviate(folder, home: context.home))))
            }
        }
        return SwitcherPreview(icon: item.icon, title: item.title, caption: facts == nil ? "Pane" : "Pane · \(kind)",
                               whereItStands: nil, rows: rows, footerAction: "Go to pane")
    }

    /// A worktree with a PR: the plot, the PR, what its stage says, and the folder.
    private static func worktree(_ item: SwitcherItem, id: String, _ context: Context) -> SwitcherPreview {
        let status = context.worktrees.first { $0.worktree.id == id }
        var rows: [Row] = []
        if let plot = item.plotName { rows.append(Row(label: "Plot", value: .text(plot))) }
        if let status, let pr = status.pr {
            rows.append(Row(label: "Pull request", value: .text("\(StageMark.numberText(pr.number)) \(pr.title)")))
            rows.append(Row(label: "Status", value: .text(StatusLine(of: status).text)))
            rows.append(Row(label: "Folder", value: .path(abbreviate(status.worktree.path, home: context.home))))
        }
        let stage = status?.stage.flatMap { $0.words.isEmpty ? nil : $0.words }
        return SwitcherPreview(icon: item.icon, title: item.title, caption: (["Worktree"] + [stage].compactMap { $0 }).joined(separator: " \u{00B7} "),
                               whereItStands: nil, rows: rows, footerAction: "Show pull request")
    }

    private static func checkout(of pane: PaneFacts, _ context: Context) -> Value? {
        if let worktree = pane.worktree { return .branch(name: worktree.name, branch: worktree.branch) }
        let repos = pane.space.plotID.flatMap { context.checkouts[$0] } ?? []
        let inside = pane.folder.flatMap { folder in repos.first { $0.holds(folder) || folder.hasPrefix($0.path + "/") } }
        guard let repo = inside ?? repos.first(where: \.isMain) else { return nil }
        return .branch(name: repo.name, branch: repo.branch)
    }

    private static func state(of pane: PaneFacts) -> Value {
        if pane.saved { return .text("Not resumed") }
        switch pane.attention {
        case .needsYou: return .attention(.needsYou, "Needs you")
        case .doneUnread: return .attention(.doneUnread, "Done, unread")
        case .none: return .text(pane.state?.label ?? "Running")
        }
    }

    private static func link(_ item: SwitcherItem, _ context: Context) -> SwitcherPreview {
        let kind = SwitcherItem.linkKindLabel(item.linkKind)
        var rows: [Row] = []
        if let target = item.linkTarget {
            let isFile = item.linkKind == .path || item.linkKind == .vault
            rows.append(Row(label: "Target", value: isFile ? .path(abbreviate(target, home: context.home)) : .text(target)))
        }
        if let plot = item.plotName { rows.append(Row(label: "Plot", value: .text(plot))) }
        return SwitcherPreview(icon: item.icon, title: item.title, caption: kind, whereItStands: nil, rows: rows,
                               footerAction: "Open link", alternateAction: item.alternate?.title)
    }

    private static func action(_ item: SwitcherItem) -> SwitcherPreview {
        let keys = item.shortcut.map(String.init)
        let rows = keys.isEmpty ? [] : [Row(label: "Shortcut", value: .keys(keys))]
        return SwitcherPreview(icon: item.icon, title: item.title, caption: "Action", whereItStands: nil, rows: rows,
                               footerAction: "Run")
    }

    // MARK: Helpers

    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    private static func folderName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    /// "~/dev/loam" for a path inside the home folder.
    static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
