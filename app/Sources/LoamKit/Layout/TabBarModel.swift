import Foundation

/// What the tab bar shows for the active plot (docs/design/components/PaneTab): one item per
/// tab, with one label (the title of the focused pane), which tab is selected, and the strongest
/// attention mark of the tab's panes.
public struct TabBarModel: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public var id: UUID
        /// 1-based, for ⌘1 to ⌘9.
        public var number: Int
        /// The one label of the tab (ticket 71): the title of its focused pane, once.
        public var title: String
        public var isSelected: Bool
        /// The strongest mark of the tab's panes: needs you, then done, unread.
        public var attention: PaneAttention = .none
        /// A pane of the tab just started to need you. The dot plays the halo.
        public var isArriving = false
        /// The pane that needs you is the focused pane of the selected tab. The halo does not run.
        public var paneFocused = false
        /// The symbol of the focused pane, before the label (ticket 88).
        public var icon: LoamIcon = .shell
    }

    public var items: [Item]

    /// `titles`: the titles that the terminals set (`AppModel.terminalTitles`).
    /// `arriving`: the panes that just started to need you (`AppModel.arrivingPanes`).
    public init(workspace: Workspace, plot: String?, titles: [PaneID: String] = [:], arriving: Set<PaneID> = []) {
        guard let plot else { items = []; return }
        let selected = workspace.selectedTab(of: plot)?.id
        items = workspace.tabs(of: plot).enumerated().map { index, tab in
            let panes = tab.tree.paneIDs
            let needs = panes.filter { workspace.attention(of: $0) == .needsYou }
            let attention: PaneAttention = !needs.isEmpty ? .needsYou
                : panes.contains { workspace.attention(of: $0) == .doneUnread } ? .doneUnread : .none
            return Item(
                id: tab.id, number: index + 1, title: workspace.title(of: tab.focused, terminalTitles: titles),
                isSelected: tab.id == selected, attention: attention,
                isArriving: needs.contains { arriving.contains($0) },
                paneFocused: tab.id == selected && needs.contains(tab.focused),
                icon: workspace.spec(of: tab.focused).map { LoamIcon.pane($0.kind) } ?? .shell)
        }
    }
}

// MARK: Pane labels (ticket 71)

extension Workspace {
    /// The title a person sees for a pane, in the tab bar, the sidebar and the switcher: the title
    /// that the terminal set, else the spec title (`claude` or `shell`).
    public func title(of pane: PaneID, terminalTitles: [PaneID: String]) -> String {
        if let set = terminalTitles[pane]?.trimmingCharacters(in: .whitespacesAndNewlines), !set.isEmpty { return set }
        return spec(of: pane)?.title ?? ""
    }

    /// The pane header rule: a pane shows its header only in a tab of two or more panes. In a tab of
    /// one pane the tab label, the tab dot and the pane ring already say what the header would say.
    public func showsHeader(_ pane: PaneID) -> Bool {
        guard let plot = spec(of: pane)?.plot,
              let tab = tabs(of: plot).first(where: { $0.tree.paneIDs.contains(pane) }) else { return false }
        return tab.tree.paneIDs.count > 1
    }
}
