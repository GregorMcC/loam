import Foundation
import Observation

/// The quick switcher (spec section 8.8): the items, the query, the ranked list, and what Return does.
///
/// Later tickets plug in here:
/// - Ticket 28 (pane sessions): live panes already show, from `AppModel.workspace`. Their title is the
///   terminal title (`AppModel.setTerminalTitle`), else the pane's spec title.
/// - Ticket 29 (restore): set `savedPanes` to the panes in `state.json` that have not resumed,
///   and `resumeSavedPane` to resume one.
/// - Ticket 32 (attention): set `attention` to read a live pane's state.
/// - Ticket 109 (PR popover): a worktree with a PR is an item. Return goes to the worktree and opens its
///   PR popover.
@MainActor
@Observable
public final class SwitcherModel {
    public private(set) var isOpen = false
    /// Counts the opens, so a view can focus its field on each one.
    public private(set) var openCount = 0
    public var query = "" { didSet { if query != oldValue { rerank() } } }
    public private(set) var results: [SwitcherResult] = []
    public var selection = 0

    @ObservationIgnored public weak var app: AppModel?
    @ObservationIgnored public var useTimes: UseTimes?
    /// The attention state of a live pane. Default: none.
    @ObservationIgnored public var attention: (PaneID) -> PaneAttention = { _ in .none }
    /// Panes in `state.json` that have not resumed. Default: none.
    @ObservationIgnored public var savedPanes: () -> [SavedPane] = { [] }
    /// Resumes a saved pane. The switcher has already made its plot active.
    @ObservationIgnored public var resumeSavedPane: (SavedPane) -> Void = { _ in }
    /// The menu commands. The window supplies them.
    @ObservationIgnored public var actions: () -> [SwitcherAction] = { [] }
    @ObservationIgnored public var runAction: (String) -> Void = { _ in }
    /// Called when the switcher opens or closes.
    @ObservationIgnored public var onOpenChange: ((Bool) -> Void)?

    /// The list shows this many rows at most.
    public static let maxRows = 60

    private var items: [SwitcherItem] = []
    private var links: [SwitcherLink] = []
    /// The plots and the change log from the last `loam export`, for the preview. Empty until it ends.
    private var details: [String: Plot] = [:]
    private var changes: [Change] = []
    private var linkTask: Task<Void, Never>?

    public init() {}

    // MARK: Open and close

    /// ⌘P opens on all items. ⌘⇧P opens with `>` typed.
    public func open(actionsOnly: Bool = false) {
        // A merge or a worktree start keeps its sheet (`sheetHoldsWindow`). The switcher would show over it, and its commands
        // would change the window under it.
        guard let app, !app.sheetHoldsWindow else { return }
        isOpen = true
        openCount += 1
        links = []
        // The preview waits for this open's export, not the last one, which can name an archived plot.
        details = [:]
        changes = []
        items = buildItems()
        query = actionsOnly ? ">" : ""
        // `query` may be unchanged (it was already ">"), so rank here as well.
        rerank()
        onOpenChange?(true)
        refreshLinks()
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        linkTask?.cancel()
        onOpenChange?(false)
    }

    // MARK: Items

    /// Reads the links of every plot that is not archived with one `loam export`.
    private func refreshLinks() {
        guard let client = app?.client else { return }
        let opened = openCount
        linkTask?.cancel()
        linkTask = Task { [weak self] in
            guard let export = try? await client.export(includeChanges: true), !Task.isCancelled else { return }
            guard let self, self.isOpen, self.openCount == opened else { return }
            self.details = Dictionary(export.plots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.changes = export.changes ?? []
            self.links = export.plots.filter { !$0.archived }.flatMap { plot in
                plot.links.map {
                    SwitcherLink(plotID: plot.id, linkID: $0.id, label: $0.label, target: $0.target, kind: $0.kind)
                }
            }
            self.items = self.buildItems()
            self.rerank(keepingSelection: true)
        }
    }

    /// The data for the preview column and the row subtitles: panes from the workspace, the plots and the
    /// change log from the last export, and the checkouts with their branches.
    public var previewContext: SwitcherPreview.Context {
        var panes: [SwitcherPreview.PaneFacts] = []
        if let app {
            let workspace = app.workspace
            for space in [Space.home] + app.plots.map({ .plot($0.id) }) {
                for pane in workspace.paneIDs(of: space) {
                    guard let spec = workspace.spec(of: pane) else { continue }
                    panes.append(SwitcherPreview.PaneFacts(
                        id: SwitcherItem.paneKey(pane.uuidString), space: space,
                        title: workspace.title(of: pane, terminalTitles: app.terminalTitles), kind: spec.kind,
                        state: workspace.state(of: pane), attention: workspace.attention(of: pane),
                        folder: workspace.folder(of: pane), worktree: spec.worktree, saved: false))
                }
            }
            for saved in savedPanes() where app.plots.contains(where: { $0.id == saved.plotID }) {
                panes.append(SwitcherPreview.PaneFacts(
                    id: SwitcherItem.paneKey(saved.id), space: .plot(saved.plotID), title: saved.title, kind: nil, state: nil,
                    attention: saved.attention, folder: nil, worktree: nil, saved: true))
            }
        }
        return SwitcherPreview.Context(
            plots: details, panes: panes, changes: changes, checkouts: app?.repoCheckouts ?? [:],
            actorText: { [weak app] in app?.review.actorLabel($0).text ?? "" },
            clock: { ChangeRules.clock($0.at) }, home: NSHomeDirectory(), worktrees: listedWorktrees)
    }

    /// The worktrees of the plots in the sidebar, in plot order.
    private var listedWorktrees: [WorktreeStatus] {
        guard let app else { return [] }
        return app.plots.flatMap { app.worktrees[$0.id] ?? [] }
    }

    func buildItems() -> [SwitcherItem] {
        guard let app else { return [] }
        let plotNames = Dictionary(app.plots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return Self.items(
            plots: app.plots,
            workspace: app.workspace,
            terminalTitles: app.terminalTitles,
            attention: attention,
            savedPanes: savedPanes().filter { plotNames[$0.plotID] != nil },
            worktrees: listedWorktrees,
            links: links.filter { plotNames[$0.plotID] != nil },
            actions: actions())
    }

    /// The items in source order: Home, plots, panes, saved panes, worktrees, links, actions.
    /// Plots that are not in `plots` (archived ones) have no items. A worktree is an item when it has a
    /// PR and its folder is there. Its match text is the PR number and the PR title, so "#142" or a word
    /// of the title finds it, also when it has no pane.
    static func items(plots: [PlotSummary], workspace: Workspace, terminalTitles: [PaneID: String],
                      attention: (PaneID) -> PaneAttention, savedPanes: [SavedPane], worktrees: [WorktreeStatus] = [],
                      links: [SwitcherLink], actions: [SwitcherAction]) -> [SwitcherItem] {
        let names = Dictionary(plots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let home = SwitcherItem(id: SwitcherItem.homeKey, kind: .plot, title: Space.homeName, target: .home, icon: .home)
        var items: [SwitcherItem] = [home] + plots.map {
            SwitcherItem(id: SwitcherItem.plotKey($0.id), kind: .plot, title: $0.name, target: .plot($0.id))
        }
        let spaces = [(space: Space.home, name: Space.homeName)] + plots.map { (space: Space.plot($0.id), name: $0.name) }
        for (space, name) in spaces {
            for pane in workspace.paneIDs(of: space) {
                guard let spec = workspace.spec(of: pane) else { continue }
                let title = workspace.title(of: pane, terminalTitles: terminalTitles)
                items.append(SwitcherItem(
                    id: SwitcherItem.paneKey(pane.uuidString), kind: .pane, title: title,
                    otherText: [name], plotName: name, attention: attention(pane), target: .pane(pane),
                    icon: .pane(spec.kind)))
            }
        }
        for saved in savedPanes {
            guard let plotName = names[saved.plotID] else { continue }
            items.append(SwitcherItem(
                id: SwitcherItem.paneKey(saved.id), kind: .pane, title: saved.title,
                otherText: [plotName], plotName: plotName, attention: saved.attention, target: .savedPane(saved)))
        }
        for status in worktrees {
            guard let pr = status.pr, !status.missing, let plotName = names[status.worktree.plotID] else { continue }
            items.append(SwitcherItem(
                id: SwitcherItem.worktreeKey(status.worktree.id), kind: .worktree, title: status.worktree.branch,
                otherText: [StageMark.numberText(pr.number), pr.title, plotName], plotName: plotName,
                target: .worktree(status.worktree.id)))
        }
        for link in links {
            guard let plotName = names[link.plotID] else { continue }
            items.append(SwitcherItem(
                id: SwitcherItem.linkKey(plot: link.plotID, link: link.linkID), kind: .link, title: link.label,
                otherText: [link.target, plotName], plotName: plotName,
                target: .link(plot: link.plotID, link: link.linkID), icon: .link(link.kind, target: link.target),
                linkKind: link.kind, linkTarget: link.target,
                // An issue starts work (ticket 115). Return still opens the link.
                alternate: IssueLink(kind: link.kind, target: link.target) == nil
                    ? nil : SwitcherItem.Alternate(title: "Start work\u{2026}", action: .startWork(link))))
        }
        for action in actions {
            items.append(SwitcherItem(
                id: "action:\(action.id)", kind: .action, title: action.title, shortcut: action.shortcut,
                target: .action(action.id)))
        }
        return items
    }

    private func rerank(keepingSelection: Bool = false) {
        let before = results.indices.contains(selection) ? results[selection].id : nil
        let ranked = Array(SwitcherRanker.rank(items, query: query, useTimes: useTimes?.all ?? [:]).prefix(Self.maxRows))
        results = Self.grouped(ranked)
        if keepingSelection, let before, let at = results.firstIndex(where: { $0.id == before }) {
            selection = at
        } else {
            selection = 0
        }
    }

    /// The results in sections by kind, as Spotlight shows them. The sections come in the order of
    /// their best result, so the best result stays first. Rank order holds inside a section.
    nonisolated static func grouped(_ results: [SwitcherResult]) -> [SwitcherResult] {
        var order: [SwitcherItem.Kind] = []
        for result in results where !order.contains(result.item.kind) { order.append(result.item.kind) }
        return order.flatMap { kind in results.filter { $0.item.kind == kind } }
    }

    /// The sections of `results`: each kind with the range of its rows.
    public var sections: [(kind: SwitcherItem.Kind, rows: Range<Int>)] {
        var sections: [(kind: SwitcherItem.Kind, rows: Range<Int>)] = []
        for (index, result) in results.enumerated() {
            if let last = sections.last, last.kind == result.item.kind {
                sections[sections.count - 1].rows = last.rows.lowerBound..<(index + 1)
            } else {
                sections.append((result.item.kind, index..<(index + 1)))
            }
        }
        return sections
    }

    // MARK: Choosing

    public func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    public func chooseSelected() {
        guard results.indices.contains(selection) else { return }
        choose(results[selection].item)
    }

    /// ⌘Return: the second action of the selected result, such as Start work… on an issue link.
    public func chooseSelectedAlternate() {
        guard results.indices.contains(selection) else { return }
        chooseAlternate(results[selection].item)
    }

    /// Does what ⌘Return does, then closes the switcher. An item with no second action does nothing, so the key never does
    /// what Return does by mistake. The plot of the issue becomes the active plot first, so the sheet opens over it.
    public func chooseAlternate(_ item: SwitcherItem) {
        guard let alternate = item.alternate, let app else { return }
        switch alternate.action {
        case .startWork(let link):
            close()
            // A worktree that is made now keeps the sheet, so the plot stays where it is.
            guard app.canOpenNewWorktree else { return }
            useTimes?.record(item.id)
            app.activate(plot: link.plotID)
            app.openNewWorktree(plot: link.plotID, from: link.plotLink)
        }
    }

    /// Does what Return does, then closes the switcher. A plot or pane switch comes first, so the
    /// close gives the keyboard to the new pane. A link or an action runs after the close.
    public func choose(_ item: SwitcherItem) {
        guard let app else { close(); return }
        switch item.target {
        case .home:
            app.activateHome()
            close()
        case .plot(let id):
            app.activate(plot: id)
            close()
        case .pane(let pane):
            if app.workspace.spec(of: pane) != nil { app.goToPane(pane) }
            useTimes?.record(item.id)  // Also when the pane already had focus in its plot.
            close()
        case .savedPane(let saved):
            app.activate(plot: saved.plotID)
            resumeSavedPane(saved)
            useTimes?.record(item.id)
            close()
        case .worktree(let id):
            app.goToWorktree(id)
            useTimes?.record(item.id)
            close()  // The keyboard goes to the pane first, so the popover remembers it.
            app.openPullRequest(id)
        case .link(let plot, let link):
            close()
            useTimes?.record(item.id)
            Task { await app.openLink(plot: plot, link: link) }
        case .action(let id):
            close()
            runAction(id)
        }
    }
}
