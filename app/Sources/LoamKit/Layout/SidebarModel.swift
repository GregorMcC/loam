import Foundation

/// What the sidebar shows, as a pure function of the stored plot order and the workspace.
/// The SwiftUI view reads it. It holds no state, so tests cover every rule in spec 8.1.
public struct SidebarModel: Equatable, Sendable {
    public struct PlotRow: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// The ⌃1 to ⌃9 number, from the stored order. Nil after the ninth plot.
        public var number: Int?
        public var paneCount: Int
        public var isActive: Bool
        /// New changes by others that you have not seen. The sidebar shows a muted ✎ count when it is above 0.
        public var newChangeCount: Int = 0
        /// The panes of the plot that need you. Above 0, the row shows the amber badge (spec 8.4).
        public var needsYouCount: Int = 0
        /// A pane of the plot is done, unread. The row shows the blue ring when no pane needs you.
        public var hasDoneUnread = false
        /// A pane of the plot just started to need you and has no focus. The badge dot plays the halo.
        public var isArriving = false
    }

    /// The Home row above the plots (ticket 99). It is always there, with no number and no change count.
    public struct HomeRow: Equatable, Sendable {
        public var paneCount: Int
        public var isActive: Bool
        /// The Home panes that need you. Above 0, the row shows the amber badge.
        public var needsYouCount: Int = 0
        /// A Home pane is done, unread. The row shows the blue ring when no pane needs you.
        public var hasDoneUnread = false
        /// A Home pane just started to need you and has no focus. The badge dot plays the halo.
        public var isArriving = false
    }

    public struct PaneRow: Equatable, Sendable, Identifiable {
        public var id: PaneID
        public var title: String
        public var state: PaneState
        public var isFocused: Bool
        public var attention: PaneAttention = .none
        /// The pane just started to need you. Its dot plays the halo while it has no focus.
        public var isArriving = false
        public var kind: PaneSpec.Kind = .shell

        /// The Claude mark for a session, `terminal` for a shell.
        public var icon: LoamIcon { .pane(kind) }
    }

    /// One row of the "Needs you" list at the top of the sidebar (spec 8.1).
    public struct NeedsYouRow: Equatable, Sendable, Identifiable {
        public var id: PaneID
        public var title: String
        public var space: Space
        /// The plot name, or "Home".
        public var plotName: String
        /// The focused pane of the active space.
        public var isFocused: Bool
        public var isArriving: Bool
    }

    /// One worktree under its plot (spec 8.1).
    public struct WorktreeRow: Equatable, Sendable, Identifiable {
        public var id: String
        public var plotID: String
        public var name: String
        public var branch: String
        /// The normal checkout of the repo. Nil when no record says it.
        public var repo: String? = nil
        /// Panes that run in the worktree, from the workspace.
        public var paneCount: Int
        /// The worktree folder is gone.
        public var missing: Bool
        public var changed: Int
        public var unpushed: Int
        /// The PR number and stage symbol, else the ✎ mark for local work, else nil (ticket 107).
        public var mark: StageMark? = nil
        /// The key of the issue that the work started from, such as "ENG-482". Nil when none (ticket 115).
        public var linkKey: String? = nil
        /// What the worktree is for. The tooltip of the row. Nil when none (ticket 115).
        public var goal: String? = nil

        /// The worktree has a PR at the Ready to merge stage.
        public var isReadyToMerge: Bool { mark?.stage == .readyToMerge }

        /// The tooltip of the row: the issue key, then the goal, else the words of the mark. The row can drop the key when
        /// the name needs the room, so the tooltip always has it (ticket 115).
        public var tooltip: String {
            [linkKey, goal ?? mark?.tooltip].compactMap { $0 }.joined(separator: StatusLine.separator)
        }
    }

    /// A tab of 2 or more panes in one checkout. It groups those panes in the tree. A tab of one
    /// pane has no row: its pane row stands for it.
    public struct TabRow: Equatable, Sendable, Identifiable {
        /// The tab ID.
        public var id: UUID
        /// The tab's focused pane, else its first pane here when the focused pane runs in another
        /// checkout. The row takes its title, and a click on the row goes to it.
        public var lead: PaneID
        /// The title of `lead`, as the tab bar shows it.
        public var title: String
        /// The panes of the tab in this checkout, in layout order.
        public var panes: [PaneRow]

        /// The strongest mark of the panes: needs you, then done, unread.
        public var attention: PaneAttention {
            panes.contains { $0.attention == .needsYou } ? .needsYou
                : panes.contains { $0.attention == .doneUnread } ? .doneUnread : .none
        }
        /// A pane of the tab just started to need you.
        public var isArriving: Bool { panes.contains { $0.isArriving && $0.attention == .needsYou } }
        /// The focused pane is in the tab.
        public var holdsFocus: Bool { panes.contains(where: \.isFocused) }
        /// The focused pane needs you. The halo does not run.
        public var needsYouFocused: Bool { panes.contains { $0.isFocused && $0.attention == .needsYou } }
    }

    /// One entry under a checkout, or under a plot with no main repo: a pane, or a tab that groups panes.
    public enum TreeItem: Equatable, Sendable, Identifiable {
        public enum ID: Hashable, Sendable {
            case pane(PaneID)
            case tab(UUID)
        }

        case pane(PaneRow)
        case tab(TabRow)

        public var id: ID {
            switch self {
            case .pane(let row): .pane(row.id)
            case .tab(let tab): .tab(tab.id)
            }
        }
    }

    /// A level under a plot in the tree (tickets 71, 76, and 92): the main checkout, another repo of the
    /// plot, or a worktree, with the panes that run in it. A repo row holds the worktrees of its repo.
    public struct CheckoutRow: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable { case main, repo, worktree }
        /// `main-<plot ID>` for the main checkout, `repo-<repo ID>` for another repo, else the worktree ID.
        public var id: String
        public var plotID: String
        public var kind: Kind
        /// The branch. In a plot with more than one repo, a repo row shows its folder name instead,
        /// with the branch in `detail`. A repo that is not a git checkout shows its folder name.
        public var label: String
        /// The branch of a repo row in a plot with more than one repo. Nil otherwise.
        public var detail: String? = nil
        /// The repo of a main or repo row. Nil for a worktree.
        public var repo: RepoCheckout? = nil
        /// The worktree and its checks. Nil for a repo row.
        public var worktree: WorktreeRow?
        /// The panes that run here, in tab order then layout order.
        public var panes: [PaneRow]
        /// The same panes as the tree shows them: a split tab groups its panes under a tab row.
        public var items: [TreeItem] = []
        /// The worktrees of a main or repo row, oldest first. They show after `items`. Empty for a worktree.
        public var worktrees: [CheckoutRow] = []
    }

    /// What a plot holds in the tree (ticket 71). Home has a tree too, with only `panes` and `items`.
    public struct PlotTree: Equatable, Sendable {
        /// The plot sessions, and the panes of a plot with no repos outside a worktree. They sit right
        /// under the plot.
        public var panes: [PaneRow] = []
        /// The same panes as the tree shows them: a split tab groups its panes under a tab row.
        public var items: [TreeItem] = []
        /// The main checkout first (only for a plot with a main repo), then the other repos, each with
        /// its worktrees. A worktree whose repo has no row comes last, right under the plot.
        public var checkouts: [CheckoutRow] = []
        public var isEmpty: Bool { panes.isEmpty && checkouts.isEmpty }
        /// Every checkout in tree order: each row, then the worktrees it holds.
        public var allCheckouts: [CheckoutRow] { checkouts.flatMap { [$0] + $0.worktrees } }
    }

    /// A row that the sidebar can select.
    public enum RowID: Hashable, Sendable {
        case home
        case plot(String)
        case pane(PaneID)
        /// A worktree row, by worktree ID. ⌘⇧L selects it when the worktree has no pane (ticket 107).
        case worktree(String)
    }

    public let plots: [PlotSummary]
    /// The worktrees of each plot, oldest first.
    public let worktreeRows: [String: [WorktreeRow]]
    public let activeSpace: Space?
    public var activePlotID: String? { activeSpace?.plotID }
    public let home: HomeRow
    /// The panes of Home, as the tree under the Home row shows them.
    public let homeTree: PlotTree
    /// Plots that own at least one pane, in stored order.
    public let withPanes: [PlotRow]
    /// Plots with no pane, in stored order. They show in a group at the bottom.
    public let noPanes: [PlotRow]
    /// The panes of the active space, in tab order then layout order.
    public let activePanes: [PaneRow]
    public let collapsed: Bool
    public let windowTitle: String
    /// Every pane that needs you, in sidebar order: Home, then plot order, then tab order, then
    /// layout order. The list at the top of the sidebar shows only while it is not empty.
    public let needsYou: [NeedsYouRow]
    /// The panes that are done, unread, in the same order. A pane that needs you is not in it.
    public let doneUnread: [PaneID]
    /// The counts on the two fixed rows under the search field (ticket 86).
    public var needsYouCount: Int { needsYou.count }
    public var doneUnreadCount: Int { doneUnread.count }
    /// The panes that need you in spaces other than the active one, for the title bar button.
    public let elsewhereNeedYou: Int
    /// The tree under each plot (ticket 71). Every plot has one. The view opens the active plot.
    public let trees: [String: PlotTree]
    /// Every worktree of the plots in the sidebar, in sidebar order: plots with panes, then the others,
    /// and in each plot the order of its tree (ticket 107). Archived plots are not in it.
    public let orderedWorktrees: [WorktreeRow]
    /// The "Ready to merge" row shows while `gh` works and a worktree has a PR (ticket 107). `gh` does
    /// not work when a worktree says `gh_missing` or `gh_signed_out`: the stages are then old, or local.
    public let showsReadyToMerge: Bool
    /// The worktrees with a PR at the Ready to merge stage, in sidebar order. Empty while the row is hidden.
    public let readyToMerge: [WorktreeRow]
    /// The count on the Ready to merge row.
    public var readyToMergeCount: Int { readyToMerge.count }
    /// Where you are: the selected worktree (⌘⇧L), else the focused pane of the active space, else the
    /// active space. The list selects it. On a page, no row of the tree is selected.
    public let selection: RowID?

    /// A fixed row at the top of the sidebar that a page belongs to.
    public enum PageRow: Equatable, Sendable { case today, intake }
    /// The fixed row of the page that the well shows, or nil while it shows the panes. The desk and a run page
    /// belong to Today, and the recurring page to Intake.
    public let pageRow: PageRow?

    /// `arriving`: the panes that just started to need you (`AppModel.arrivingPanes`).
    /// `repos`: the repos of each plot with their branches, main repo first (`AppModel.repoCheckouts`).
    /// A plot with no entry has no repos. `titles`: the titles that the terminals set (`AppModel.terminalTitles`).
    /// `selectedWorktree`: the worktree that ⌘⇧L selected (`AppModel.selectedWorktree`). It selects its row
    /// only while it is a worktree of the active plot. `page`: the page that the well shows (`AppModel.page`).
    /// `runWorktrees`: the worktrees of the runs that have not ended.
    public init(plots: [PlotSummary], workspace: Workspace, collapsed: Bool, newChangeCounts: [String: Int] = [:],
                worktrees: [String: [WorktreeStatus]] = [:], arriving: Set<PaneID> = [],
                repos: [String: [RepoCheckout]] = [:], titles: [PaneID: String] = [:], selectedWorktree: String? = nil,
                page: AppPage? = nil, runWorktrees: Set<String> = []) {
        self.plots = plots
        let links = SessionLinks(worktrees)
        var panesIn: [String: Int] = [:]
        for id in workspace.allPaneIDs {
            if let worktree = workspace.shownWorktree(of: id, links: links) { panesIn[worktree.id, default: 0] += 1 }
        }
        worktreeRows = worktrees.mapValues { list in
            list.map {
                WorktreeRow(id: $0.worktree.id, plotID: $0.worktree.plotID, name: $0.worktree.name,
                            branch: $0.worktree.branch, repo: $0.worktree.repo, paneCount: panesIn[$0.worktree.id] ?? 0,
                            missing: $0.missing, changed: $0.changed, unpushed: $0.unpushed, mark: StageMark($0),
                            linkKey: $0.worktree.link.flatMap { $0.key.isEmpty ? nil : $0.key },
                            goal: $0.worktree.goal.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
        self.collapsed = collapsed
        let activeSpace = workspace.activeSpace
        self.activeSpace = activeSpace
        let active = activeSpace?.plotID
        let focused = workspace.focusedPane
        let homePanes = workspace.paneIDs(of: .home)
        let homeNeeds = homePanes.filter { workspace.attention(of: $0) == .needsYou }
        home = HomeRow(paneCount: homePanes.count, isActive: activeSpace == .home, needsYouCount: homeNeeds.count,
                       hasDoneUnread: homePanes.contains { workspace.attention(of: $0) == .doneUnread },
                       isArriving: homeNeeds.contains { arriving.contains($0) && $0 != focused })
        let rows = plots.enumerated().map { index, plot in
            let panes = workspace.paneIDs(of: .plot(plot.id))
            let needs = panes.filter { workspace.attention(of: $0) == .needsYou }
            return PlotRow(id: plot.id, name: plot.name, number: index < 9 ? index + 1 : nil,
                           paneCount: panes.count, isActive: plot.id == active,
                           newChangeCount: plot.id == active ? 0 : (newChangeCounts[plot.id] ?? 0),
                           needsYouCount: needs.count,
                           hasDoneUnread: panes.contains { workspace.attention(of: $0) == .doneUnread },
                           isArriving: needs.contains { arriving.contains($0) && $0 != focused })
        }
        withPanes = rows.filter { $0.paneCount > 0 }
        noPanes = rows.filter { $0.paneCount == 0 }
        func paneRows(of space: Space) -> [PaneRow] {
            workspace.paneIDs(of: space).compactMap { id in
                guard let spec = workspace.spec(of: id) else { return nil }
                return PaneRow(id: id, title: workspace.title(of: id, terminalTitles: titles),
                               state: workspace.state(of: id) ?? .running, isFocused: id == focused,
                               attention: workspace.attention(of: id), isArriving: arriving.contains(id),
                               kind: spec.kind)
            }
        }
        // One pass builds the pane rows of each plot. The active plot's list and the trees share them.
        let rowsByPlot = Dictionary(plots.map { ($0.id, paneRows(of: .plot($0.id))) }) { first, _ in first }
        let homeRows = paneRows(of: .home)
        homeTree = PlotTree(panes: homeRows, items: Self.items(homeRows, tabs: workspace.tabs(of: .home)))
        activePanes = switch activeSpace {
        case .home: homeRows
        case .plot(let id): rowsByPlot[id] ?? paneRows(of: .plot(id))
        case nil: []
        }
        let worktreeRows = self.worktreeRows
        trees = rowsByPlot.reduce(into: [:]) { all, entry in
            all[entry.key] = Self.tree(of: entry.key, panes: entry.value, workspace: workspace, links: links,
                                       worktrees: worktreeRows[entry.key] ?? [], repos: repos[entry.key] ?? [])
        }
        let treeOfPlot = self.trees
        let ordered = (withPanes + noPanes).flatMap { treeOfPlot[$0.id]?.allCheckouts.compactMap(\.worktree) ?? [] }
        orderedWorktrees = ordered
        // The row needs `gh` to work and a PR to show. A worktree of an archived plot does not count.
        let statuses = plots.flatMap { worktrees[$0.id] ?? [] }
        let ghWorks = !statuses.contains(where: \.holdsGitHubNote)
        showsReadyToMerge = ghWorks && statuses.contains { $0.pr != nil }
        // A worktree of a run that has not ended lands at the desk, with its run.
        readyToMerge = showsReadyToMerge ? ordered.filter { $0.isReadyToMerge && !runWorktrees.contains($0.id) } : []
        pageRow = switch page {
        case nil: nil
        case .today, .desk, .run: .today
        case .intake, .recurring: .intake
        }
        selection = page != nil ? nil : activeSpace.map { space -> RowID in
            if let selectedWorktree, ordered.contains(where: { $0.id == selectedWorktree && $0.plotID == space.plotID }) {
                return .worktree(selectedWorktree)
            }
            return focused.map(RowID.pane) ?? space.plotID.map(RowID.plot) ?? .home
        }
        let spaces = [(space: Space.home, name: Space.homeName)] + plots.map { (space: Space.plot($0.id), name: $0.name) }
        needsYou = spaces.flatMap { space, name in
            workspace.paneIDs(of: space).filter { workspace.attention(of: $0) == .needsYou }.map { id in
                NeedsYouRow(id: id, title: workspace.title(of: id, terminalTitles: titles), space: space,
                            plotName: name, isFocused: id == focused, isArriving: arriving.contains(id))
            }
        }
        doneUnread = spaces.flatMap { workspace.paneIDs(of: $0.space) }.filter { workspace.attention(of: $0) == .doneUnread }
        elsewhereNeedYou = needsYou.filter { $0.space != activeSpace }.count
        // The toolbar title (ticket 68).
        windowTitle = switch activeSpace {
        case .home: Space.homeName
        case .plot(let id): plots.first { $0.id == id }?.name ?? "Loam"
        case nil: "Loam"
        }
    }

    /// Groups the panes of one plot by the worktree that each shows under (`Workspace.shownWorktree`), then
    /// by `PaneSpec.repo`. A session that works in a worktree sits under it, wherever it started (TAS-55). A
    /// plot session (ticket 93) sits right under the plot, before the repo rows. A pane in another
    /// repo of the plot sits under that repo's row. The main checkout holds the other panes. A plot
    /// with no repos holds them itself. Each worktree nests under the row of its repo (ticket 92). A
    /// worktree that the list misses (it can reload while a pane runs in it) still gets its row, after
    /// the listed ones. With no repo in its reference, it nests under the main repo.
    private static func tree(of plot: String, panes: [PaneRow], workspace: Workspace, links: SessionLinks,
                             worktrees: [WorktreeRow], repos: [RepoCheckout]) -> PlotTree {
        let main = repos.first(where: \.isMain)
        let others = repos.filter { !$0.isMain }
        var outside: [PaneRow] = []
        var inPlot: [PaneRow] = []
        var inRepo: [String: [PaneRow]] = [:]
        var inside: [String: [PaneRow]] = [:]
        var unlisted: [WorktreeRef] = []
        let listed = Set(worktrees.map(\.id))
        for pane in panes {
            let spec = workspace.spec(of: pane.id)
            guard let ref = workspace.shownWorktree(of: pane.id, links: links) else {
                if spec?.inPlotFolder == true {
                    inPlot.append(pane)
                } else if let repo = spec?.repo.flatMap({ path in others.first { $0.holds(path) } }) {
                    inRepo[repo.id, default: []].append(pane)
                } else if main != nil {
                    outside.append(pane)
                } else {
                    inPlot.append(pane)  // tab order holds with the plot sessions
                }
                continue
            }
            if !listed.contains(ref.id), !unlisted.contains(where: { $0.id == ref.id }) { unlisted.append(ref) }
            inside[ref.id, default: []].append(pane)
        }
        let tabs = workspace.tabs(of: .plot(plot))
        // With more than one repo, a branch name alone does not say which repo a row is.
        let named = repos.count > 1
        var tree = PlotTree()
        if let main {
            tree.checkouts.append(CheckoutRow(id: "main-\(plot)", plotID: plot, kind: .main,
                                              label: named ? main.name : main.label, detail: named ? main.branch : nil,
                                              repo: main, worktree: nil, panes: outside, items: items(outside, tabs: tabs)))
        }
        tree.panes = inPlot
        tree.items = items(inPlot, tabs: tabs)
        tree.checkouts += others.map {
            let held = inRepo[$0.id] ?? []
            return CheckoutRow(id: "repo-\($0.id)", plotID: plot, kind: .repo, label: $0.name, detail: $0.branch,
                               repo: $0, worktree: nil, panes: held, items: items(held, tabs: tabs))
        }
        let missed = unlisted.map {
            WorktreeRow(id: $0.id, plotID: plot, name: $0.name, branch: $0.branch, repo: $0.repo ?? main?.path,
                        paneCount: inside[$0.id]?.count ?? 0, missing: false, changed: 0, unpushed: 0)
        }
        var homeless: [CheckoutRow] = []
        for worktree in worktrees + missed {
            let row = CheckoutRow(id: worktree.id, plotID: plot, kind: .worktree, label: worktree.branch, worktree: worktree,
                                  panes: inside[worktree.id] ?? [], items: items(inside[worktree.id] ?? [], tabs: tabs))
            if let path = worktree.repo,
               let index = tree.checkouts.firstIndex(where: { $0.repo?.holds(path) == true }) {
                tree.checkouts[index].worktrees.append(row)
            } else {
                homeless.append(row)
            }
        }
        tree.checkouts += homeless
        return tree
    }

    /// Groups the panes of one checkout by tab. The panes come in tab order, so the panes of a tab
    /// sit together. Two or more of them make a tab row. One stays a pane row.
    private static func items(_ panes: [PaneRow], tabs: [Tab]) -> [TreeItem] {
        var tabOf: [PaneID: Tab] = [:]
        for tab in tabs { for pane in tab.tree.paneIDs { tabOf[pane] = tab } }
        var items: [TreeItem] = []
        var index = 0
        while index < panes.count {
            let tab = tabOf[panes[index].id]
            var end = index + 1
            while end < panes.count, let tab, tabOf[panes[end].id]?.id == tab.id { end += 1 }
            let group = Array(panes[index..<end])
            if let tab, group.count > 1 {
                let lead = group.first { $0.id == tab.focused } ?? group[0]
                items.append(.tab(TabRow(id: tab.id, lead: lead.id, title: lead.title, panes: group)))
            } else {
                items += group.map(TreeItem.pane)
            }
            index = end
        }
        return items
    }

    /// The tree under the plot. Empty for an unknown plot.
    public func tree(of plot: String) -> PlotTree { trees[plot] ?? PlotTree() }

    /// The checkout that holds the pane. Nil for a pane that sits right under its plot, or an unknown pane.
    public func checkout(holding pane: PaneID) -> CheckoutRow? {
        trees.values.lazy.flatMap(\.allCheckouts).first { $0.panes.contains { $0.id == pane } }
    }

    /// The repo row that lists the worktree (ticket 92). Nil for a worktree right under its plot, and for an
    /// unknown worktree.
    public func repoRow(holding worktree: String) -> CheckoutRow? {
        trees.values.lazy.flatMap(\.checkouts).first { $0.worktrees.contains { $0.id == worktree } }
    }

    /// The tab row that holds the pane. Nil for a pane that has no tab row, or an unknown pane.
    public func tab(holding pane: PaneID) -> TabRow? {
        for tree in trees.values {
            for case .tab(let tab) in tree.items + tree.allCheckouts.flatMap(\.items)
            where tab.panes.contains(where: { $0.id == pane }) {
                return tab
            }
        }
        return nil
    }

    /// The plot behind ⌃`number`. Nil when there is no such plot.
    public func plotID(forNumber number: Int) -> String? {
        guard number >= 1, number <= 9, number <= plots.count else { return nil }
        return plots[number - 1].id
    }

    public func plotID(after id: String) -> String? { step(from: id, by: 1) }
    public func plotID(before id: String) -> String? { step(from: id, by: -1) }

    private func step(from id: String, by offset: Int) -> String? {
        guard let i = plots.firstIndex(where: { $0.id == id }) else { return nil }
        return plots[(i + offset + plots.count) % plots.count].id
    }

    /// A group of plot rows in the sidebar. A plot drags only within its own section (ticket 98).
    public enum Section: Equatable, Sendable {
        case withPanes, noPanes
    }

    /// The section that shows the plot. Nil for a plot that is not in the sidebar.
    public func section(of plot: String) -> Section? {
        if withPanes.contains(where: { $0.id == plot }) { return .withPanes }
        if noPanes.contains(where: { $0.id == plot }) { return .noPanes }
        return nil
    }

    /// The plot IDs of a section, in the order the sidebar shows them.
    public func plotIDs(in section: Section) -> [String] {
        (section == .withPanes ? withPanes : noPanes).map(\.id)
    }

    /// The store order after `moving` goes to `slot` of its section (0 based, the index it has after
    /// the move). `order` is the full store order: both sections, and the archived plots that the
    /// sidebar does not show. The plot goes right after the plot above its slot in the section, or
    /// right before the plot below it at the top of the section. Nil for the slot it has now, an
    /// unknown plot or slot, or when the store order already has the plot there.
    public func order(moving: String, toSlot slot: Int, in order: [String]) -> [String]? {
        guard let section = section(of: moving), let from = order.firstIndex(of: moving) else { return nil }
        let ids = plotIDs(in: section)
        let others = ids.filter { $0 != moving }
        guard slot >= 0, slot <= others.count, ids.firstIndex(of: moving) != slot else { return nil }
        var rest = order
        rest.remove(at: from)
        let index: Int
        if slot > 0, let above = rest.firstIndex(of: others[slot - 1]) {
            index = above + 1
        } else if slot < others.count, let below = rest.firstIndex(of: others[slot]) {
            index = below
        } else {
            return nil
        }
        rest.insert(moving, at: index)
        return rest == order ? nil : rest
    }

    /// The 1-based position to pass to `loam move` when `moving` goes to `slot` of its section, from
    /// the full store order. Nil when nothing moves.
    public func movePosition(moving: String, toSlot slot: Int, in order: [String]) -> Int? {
        self.order(moving: moving, toSlot: slot, in: order).flatMap { $0.firstIndex(of: moving) }.map { $0 + 1 }
    }
}

/// One repo of a plot for the sidebar tree (ticket 76), with the branch of its folder.
public struct RepoCheckout: Equatable, Sendable, Identifiable {
    public var id: String
    public var path: String
    public var isMain: Bool
    /// The branch. Nil until it is read, or when the folder is not a git checkout.
    public var branch: String?

    public init(id: String, path: String, isMain: Bool, branch: String? = nil) {
        self.id = id
        self.path = path
        self.isMain = isMain
        self.branch = branch
    }

    /// The folder name.
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    /// The branch, else the folder name.
    public var label: String { branch ?? name }

    /// True when `path` names this repo's folder.
    func holds(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path == URL(fileURLWithPath: self.path).standardizedFileURL.path
    }
}

/// Which rows of the sidebar tree are open (ticket 71). The active space (Home or a plot) opens by
/// itself, so by default only the active space shows its panes (spec 8.1). A space that opened that
/// way closes when another space becomes active. A space that you open stays open until you close
/// it. A checkout (the main checkout or a worktree) and a tab row are open until you close them.
public struct SidebarDisclosure: Equatable, Sendable {
    public private(set) var openSpaces: Set<Space> = []
    private var active: Space?
    /// The space that opened because it became active.
    private var autoOpened: Space?
    private var closedCheckouts: Set<String> = []
    private var closedTabs: Set<UUID> = []

    public init() {}

    public func isOpen(_ space: Space) -> Bool { openSpaces.contains(space) }
    /// Whether the space is open once `active` is the active space. The view reads this one: it renders
    /// a new active space before `activeSpaceChanged` runs, and the list must add a plot that gets its
    /// first pane in that render as closed. Else the list opens the plot later by a write (map 74).
    public func isOpen(_ space: Space, active: Space?) -> Bool {
        var next = self
        next.activeSpaceChanged(to: active)
        return next.isOpen(space)
    }
    public func isOpen(checkout: String) -> Bool { !closedCheckouts.contains(checkout) }
    public func isOpen(tab: UUID) -> Bool { !closedTabs.contains(tab) }

    /// Call it with the active space on each change. The same space again changes nothing.
    public mutating func activeSpaceChanged(to space: Space?) {
        guard space != active else { return }
        active = space
        if let old = autoOpened {
            openSpaces.remove(old)
            autoOpened = nil
        }
        guard let space, !openSpaces.contains(space) else { return }
        openSpaces.insert(space)
        autoOpened = space
    }

    /// You opened or closed the space. Your choice holds when the active space changes. A write that
    /// does not change the state is not a choice: the list writes `true` to a plot row that it adds as
    /// open, and that must not keep the plot open when you leave it (map 74).
    public mutating func setSpace(_ space: Space, open: Bool) {
        guard open != isOpen(space) else { return }
        if open { openSpaces.insert(space) } else { openSpaces.remove(space) }
        if space == autoOpened { autoOpened = nil }
    }

    public mutating func setCheckout(_ checkout: String, open: Bool) {
        if open { closedCheckouts.remove(checkout) } else { closedCheckouts.insert(checkout) }
    }

    public mutating func setTab(_ tab: UUID, open: Bool) {
        if open { closedTabs.remove(tab) } else { closedTabs.insert(tab) }
    }
}

/// The rule behind a click on "Needs you" or "Done, unread" (ticket 86): the next pane in a state
/// after the focused pane, in sidebar order, round to the start. With no focused pane in the order,
/// the first pane in the state. Nil when no pane is in the state. The "Ready to merge" row uses it
/// for worktrees (ticket 107).
public enum AttentionCycle {
    public static func next<ID: Hashable>(order: [ID], matching: Set<ID>, after current: ID?) -> ID? {
        guard !matching.isEmpty else { return nil }
        guard let current, let i = order.firstIndex(of: current) else { return order.first(where: matching.contains) }
        return (order[(i + 1)...] + order[...i]).first(where: matching.contains)
    }
}
