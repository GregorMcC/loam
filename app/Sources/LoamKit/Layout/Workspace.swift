import Foundation

/// What a pane runs. The pane view factory builds a view from this.
public struct PaneSpec: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case shell, session }

    public var kind: Kind
    /// The plot ID that owns the pane.
    public var plot: String
    public var folder: String?
    public var command: String?
    public var env: [String: String]
    /// The session name or shell label shown in the pane header.
    public var title: String
    /// The repo that a seeded pane names with `--repo`. Nil for the main repo.
    public var repo: String?
    /// The session ID that a seeded pane starts or resumes with. The current ID is in `PaneSession`.
    public var sessionID: String?
    /// The worktree that the pane runs in. The pane header shows its branch. Nil outside a worktree.
    public var worktree: WorktreeRef?
    /// True for a plot session (ticket 93): it starts in the plot folder, not in a repo. Optional, so a
    /// pane saved before the field existed still decodes. Use `inPlotFolder`.
    public var plotFolder: Bool?

    /// The pane starts in the plot folder. The sidebar shows it right under its plot.
    public var inPlotFolder: Bool {
        get { plotFolder ?? false }
        set { plotFolder = newValue ? true : nil }
    }

    public init(kind: Kind, plot: String, folder: String? = nil, command: String? = nil,
                env: [String: String] = [:], title: String = "shell", repo: String? = nil, sessionID: String? = nil,
                worktree: WorktreeRef? = nil) {
        self.kind = kind
        self.plot = plot
        self.folder = folder
        self.command = command
        self.env = env
        self.title = title
        self.repo = repo
        self.sessionID = sessionID
        self.worktree = worktree
    }
}

/// The state in the pane header. A shell pane stays `running`. A seeded pane is `running` until
/// its session starts, then `idle`, `working`, or `needsYou`, and `ended` after `SessionEnd` or the
/// process exit. Needs you is one of the 2 alert states (spec 8.4). Done, unread is the other. It is
/// a flag on the session (`PaneSession.doneUnread`), not a state.
public enum PaneState: String, Codable, Sendable {
    case running
    case idle
    case working
    case needsYou
    case ended

    /// The words in the pane header, in sentence case (docs/design).
    public var label: String {
        switch self {
        case .running: "Running"
        case .idle: "Idle"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .ended: "Ended"
        }
    }
}

/// One tab: a split tree and the focused pane.
public struct Tab: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var tree: SplitTree
    public var focused: PaneID
}

/// The tabs and splits of every plot, plus the active plot. A value type with no views in it,
/// so tests cover it. The window turns it into views, and `state.json` (ticket 29) can encode it.
public struct Workspace: Codable, Equatable, Sendable {
    public private(set) var activePlotID: String?
    private var plotTabs: [String: [Tab]] = [:]
    private var selectedIndex: [String: Int] = [:]
    private var specs: [PaneID: PaneSpec] = [:]
    private var sessions: [PaneID: PaneSession] = [:]
    private var launches: [PaneID: Int] = [:]
    /// Plots restored from `state.json` that were not shown since the launch. Their panes have no
    /// process yet: a pane starts when its plot is first shown (spec 8.5).
    private var waitingPlots: Set<String> = []

    public init() {}

    // MARK: Reads

    public func tabs(of plot: String) -> [Tab] { plotTabs[plot] ?? [] }

    public func selectedTab(of plot: String) -> Tab? {
        let tabs = tabs(of: plot)
        guard let i = selectedIndex[plot], tabs.indices.contains(i) else { return nil }
        return tabs[i]
    }

    public func selectedTabIndex(of plot: String) -> Int? {
        selectedTab(of: plot) == nil ? nil : selectedIndex[plot]
    }

    /// Every pane of the plot in tab order, then layout order.
    public func paneIDs(of plot: String) -> [PaneID] { tabs(of: plot).flatMap { $0.tree.paneIDs } }
    public func paneCount(of plot: String) -> Int { paneIDs(of: plot).count }
    public var allPaneIDs: [PaneID] { plotTabs.values.flatMap { $0.flatMap { $0.tree.paneIDs } } }
    public func spec(of pane: PaneID) -> PaneSpec? { specs[pane] }
    public func state(of pane: PaneID) -> PaneState? { sessions[pane]?.state }
    public func session(of pane: PaneID) -> PaneSession? { sessions[pane] }

    /// The alert state of a pane (spec 8.4). Needs you wins over done, unread.
    public func attention(of pane: PaneID) -> PaneAttention {
        guard let session = sessions[pane] else { return .none }
        if session.state == .needsYou { return .needsYou }
        return session.doneUnread ? .doneUnread : .none
    }

    /// The pane that you see with the keys: the focused pane of the active plot's selected tab.
    /// The app counts it as looked at only while Loam is frontmost.
    public var focusedPane: PaneID? { activePlotID.flatMap { selectedTab(of: $0)?.focused } }

    /// The seeded pane that runs or ran this session ID. The current ID wins over an old one.
    public func pane(forSession id: String) -> PaneID? {
        let seeded = sessions.filter { specs[$0.key]?.kind == .session }
        return seeded.first { $0.value.sessionID == id }?.key ?? seeded.first { $0.value.ran(id) }?.key
    }
    public var plotIDsWithPanes: [String] { plotTabs.filter { !$0.value.isEmpty }.map(\.key) }

    // MARK: Restored panes that wait

    /// True when the plot's panes came from `state.json` and the plot was not shown yet.
    public func isWaiting(_ plot: String) -> Bool { waitingPlots.contains(plot) }
    /// The saved panes of the plot that have not started (resumed) yet. Empty once the plot shows.
    public func waitingPaneIDs(of plot: String) -> [PaneID] { isWaiting(plot) ? paneIDs(of: plot) : [] }
    /// The panes of the plot that have a view and a process now. Empty while the plot waits.
    public func livePaneIDs(of plot: String) -> [PaneID] { isWaiting(plot) ? [] : paneIDs(of: plot) }
    /// Every saved pane that has not started yet, in every plot.
    public var waitingPaneIDs: [PaneID] { waitingPlots.sorted().flatMap { paneIDs(of: $0) } }
    /// The panes that have a view and a process: every pane except the waiting ones.
    public var livePaneIDs: [PaneID] { allPaneIDs.filter { specs[$0].map { !waitingPlots.contains($0.plot) } ?? false } }
    /// The working folder of a pane: its worktree, else where its session started (from `SessionStart`),
    /// else the spec folder.
    public func folder(of pane: PaneID) -> String? {
        specs[pane]?.worktree?.path ?? sessions[pane]?.folder ?? specs[pane]?.folder
    }

    /// Puts back the saved tabs of a plot. Every tree leaf must have a spec and a session. The panes
    /// wait until `activate(plot:)` shows the plot. A plot that already has tabs changes nothing.
    public mutating func restorePlot(_ plot: String, tabs: [Tab], selected: Int,
                                     specs newSpecs: [PaneID: PaneSpec], sessions newSessions: [PaneID: PaneSession]) {
        guard plotTabs[plot, default: []].isEmpty, !tabs.isEmpty else { return }
        let panes = tabs.flatMap { $0.tree.paneIDs }
        guard panes.allSatisfy({ newSpecs[$0]?.plot == plot && newSessions[$0] != nil && specs[$0] == nil }) else { return }
        for pane in panes { specs[pane] = newSpecs[pane]; sessions[pane] = newSessions[pane] }
        plotTabs[plot] = tabs
        selectedIndex[plot] = min(max(selected, 0), tabs.count - 1)
        if plot != activePlotID { waitingPlots.insert(plot) }
    }

    // MARK: Plots

    /// Ends the plot's panes and keeps the layout (archive, spec section 10). The plot waits, like a
    /// restored plot: `activate(plot:)` starts each pane again. `respec` gives the spec that brings a
    /// pane back. Each session starts clean with its current ID, so a stale `working` mark is gone.
    /// The plot stops being active.
    public mutating func suspendPlot(_ plot: String, respec: (PaneID, PaneSpec, PaneSession) -> PaneSpec) {
        let panes = paneIDs(of: plot)
        if activePlotID == plot { activePlotID = nil }
        guard !panes.isEmpty else { return }
        for pane in panes {
            guard let spec = specs[pane], let session = sessions[pane] else { continue }
            specs[pane] = respec(pane, spec, session)
            sessions[pane] = PaneSession(sessionID: session.sessionID ?? spec.sessionID, pastSessionIDs: session.pastSessionIDs,
                                         folder: session.folder, doneUnread: session.doneUnread)
        }
        waitingPlots.insert(plot)
    }

    /// Makes the plot active. A plot that waits is shown now, so its panes start.
    public mutating func activate(plot: String?) {
        activePlotID = plot
        if let plot { waitingPlots.remove(plot) }
    }

    /// Drops the plot's tabs. Returns the pane IDs, so the caller can close their views.
    @discardableResult
    public mutating func removePlot(_ plot: String) -> [PaneID] {
        let removed = paneIDs(of: plot)
        for id in removed { specs[id] = nil; sessions[id] = nil; launches[id] = nil }
        plotTabs[plot] = nil
        selectedIndex[plot] = nil
        waitingPlots.remove(plot)
        if activePlotID == plot { activePlotID = nil }
        return removed
    }

    // MARK: Tabs

    /// Opens a tab with one pane, in the plot named by `spec.plot`, and selects it.
    @discardableResult
    public mutating func openTab(_ spec: PaneSpec) -> PaneID {
        let pane = PaneID()
        specs[pane] = spec
        sessions[pane] = PaneSession(sessionID: spec.sessionID)
        plotTabs[spec.plot, default: []].append(Tab(id: UUID(), tree: .leaf(pane), focused: pane))
        selectedIndex[spec.plot] = plotTabs[spec.plot]!.count - 1
        return pane
    }

    /// Selects tab `number` (1 based). 9 selects the last tab, as in Ghostty. Other numbers out of range change nothing.
    public mutating func selectTab(number: Int, in plot: String) {
        let count = tabs(of: plot).count
        if number == 9, count > 0 { selectedIndex[plot] = count - 1 }
        else if number >= 1, number <= count { selectedIndex[plot] = number - 1 }
    }

    /// Selects the tab at `index` (0 based), for a click on the tab bar. Out of range changes nothing.
    public mutating func selectTab(index: Int, in plot: String) {
        if tabs(of: plot).indices.contains(index) { selectedIndex[plot] = index }
    }

    /// Moves the tab at `from` to `to` (0 based, the index it has after the move), for a drag in the
    /// tab bar (ticket 98). The same tab stays selected. An index out of range changes nothing.
    public mutating func moveTab(from: Int, to: Int, in plot: String) {
        guard var tabs = plotTabs[plot], tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let selected = selectedTab(of: plot)?.id
        tabs.insert(tabs.remove(at: from), at: to)
        plotTabs[plot] = tabs
        if let selected { selectedIndex[plot] = tabs.firstIndex { $0.id == selected } }
    }

    public mutating func nextTab(in plot: String) { stepTab(1, in: plot) }
    public mutating func previousTab(in plot: String) { stepTab(-1, in: plot) }

    private mutating func stepTab(_ offset: Int, in plot: String) {
        let count = tabs(of: plot).count
        guard count > 0, let i = selectedIndex[plot] else { return }
        selectedIndex[plot] = (i + offset + count) % count
    }

    // MARK: Panes

    /// Splits the focused pane of the plot's selected tab. The new pane gets focus.
    /// Returns nil when the plot has no tab.
    @discardableResult
    public mutating func split(plot: String, axis: SplitAxis, _ spec: PaneSpec) -> PaneID? {
        guard let i = selectedTabIndex(of: plot) else { return nil }
        let pane = PaneID()
        specs[pane] = spec
        sessions[pane] = PaneSession(sessionID: spec.sessionID)
        var tab = plotTabs[plot]![i]
        tab.tree = tab.tree.splitting(tab.focused, axis: axis, inserting: pane)
        tab.focused = pane
        plotTabs[plot]![i] = tab
        return pane
    }

    /// Edits the tree of the plot's selected tab. Nothing happens when the plot has no tab.
    private mutating func editTree(plot: String, _ edit: (SplitTree) -> SplitTree) {
        guard let i = selectedTabIndex(of: plot) else { return }
        plotTabs[plot]![i].tree = edit(plotTabs[plot]![i].tree)
    }

    /// Sets the ratio of one split in the selected tab (a divider drag). `path` is `SplitTree.Divider.path`.
    public mutating func setRatio(_ ratio: Double, at path: [Int], plot: String) {
        editTree(plot: plot) { $0.settingRatio(ratio, at: path) }
    }

    /// Ghostty `equalize_splits`: gives every pane of the selected tab equal size.
    public mutating func equalize(plot: String) {
        editTree(plot: plot) { $0.equalized() }
    }

    /// Ghostty `resize_split`: moves the divider next to `pane` by `delta`, a fraction of its split.
    public mutating func resize(plot: String, pane: PaneID, toward direction: SplitTree.ResizeDirection, by delta: Double) {
        editTree(plot: plot) { $0.resizing(pane, toward: direction, by: delta) }
    }

    /// Removes the pane. A neighbour pane gets focus. The last pane of a tab closes the tab.
    public mutating func closePane(_ pane: PaneID) {
        guard let plot = specs[pane]?.plot, var tabs = plotTabs[plot],
              let i = tabs.firstIndex(where: { $0.tree.contains(pane) }) else { return }
        specs[pane] = nil
        sessions[pane] = nil
        launches[pane] = nil
        if let tree = tabs[i].tree.removing(pane) {
            if tabs[i].focused == pane { tabs[i].focused = tabs[i].tree.pane(after: pane) ?? tree.paneIDs[0] }
            tabs[i].tree = tree
        } else {
            tabs.remove(at: i)
            let selected = selectedIndex[plot] ?? 0
            selectedIndex[plot] = tabs.isEmpty ? nil : (i < selected ? selected - 1 : min(selected, tabs.count - 1))
        }
        plotTabs[plot] = tabs
    }

    /// Focuses the pane and selects its tab.
    public mutating func focus(_ pane: PaneID) {
        guard let plot = specs[pane]?.plot, var tabs = plotTabs[plot],
              let i = tabs.firstIndex(where: { $0.tree.contains(pane) }) else { return }
        tabs[i].focused = pane
        plotTabs[plot] = tabs
        selectedIndex[plot] = i
    }

    /// Focuses the pane next to the focused one on one side. Nothing happens at the edge.
    public mutating func focusPane(toward direction: SplitTree.ResizeDirection, in plot: String) {
        guard let tab = selectedTab(of: plot), let next = tab.tree.pane(nextTo: tab.focused, toward: direction) else { return }
        focus(next)
    }

    /// Ghostty `close_tab`: closes every pane of the selected tab.
    public mutating func closeSelectedTab(in plot: String) {
        guard let tab = selectedTab(of: plot) else { return }
        closeTab(tab.id, in: plot)
    }

    /// Closes every pane of one tab, selected or not. The selection stays on the same tab, unless
    /// that tab is the one that closes (ticket 96).
    public mutating func closeTab(_ id: UUID, in plot: String) {
        guard let tab = tabs(of: plot).first(where: { $0.id == id }) else { return }
        for pane in tab.tree.paneIDs { closePane(pane) }
    }

    public mutating func focusNextPane(in plot: String) { stepPane(1, in: plot) }
    public mutating func focusPreviousPane(in plot: String) { stepPane(-1, in: plot) }

    private mutating func stepPane(_ offset: Int, in plot: String) {
        guard let tab = selectedTab(of: plot) else { return }
        let next = offset > 0 ? tab.tree.pane(after: tab.focused) : tab.tree.pane(before: tab.focused)
        if let next { focus(next) }
    }

    public mutating func setState(_ state: PaneState, of pane: PaneID) {
        if specs[pane] != nil { sessions[pane]?.state = state }
    }

    // MARK: Sessions in panes

    /// Applies a line from the pane's socket. A shell pane raises no state (spec 8.4), so it
    /// ignores the line. Returns true when the pane changed.
    @discardableResult
    public mutating func apply(_ event: PaneEvent, to pane: PaneID) -> Bool {
        guard specs[pane]?.kind == .session else { return false }
        return sessions[pane]?.apply(event) ?? false
    }

    /// The pane's process exited. A seeded pane stays and shows "Session ended".
    public mutating func processExited(_ pane: PaneID) {
        sessions[pane]?.processExited()
    }

    /// You typed in the pane: needs you clears (spec 8.4). Returns true when it cleared.
    @discardableResult
    public mutating func typed(in pane: PaneID) -> Bool {
        sessions[pane]?.typed() ?? false
    }

    /// You looked at the pane: done, unread clears (spec 8.4). Returns true when it cleared.
    @discardableResult
    public mutating func markSeen(_ pane: PaneID) -> Bool {
        guard sessions[pane]?.doneUnread == true else { return false }
        sessions[pane]?.doneUnread = false
        return true
    }

    /// Runs a new command in the pane: the same pane ID, place, and focus, with a new spec and a new
    /// session. `launch(of:)` goes up by one, so the window closes the old view and starts a new one.
    /// The plot cannot change. Returns false when the pane is gone.
    @discardableResult
    public mutating func restartPane(_ pane: PaneID, with spec: PaneSpec) -> Bool {
        guard let old = specs[pane], old.plot == spec.plot else { return false }
        specs[pane] = spec
        // The pane keeps the IDs it ran, so a change by an earlier session still finds it.
        var past = sessions[pane].map { $0.pastSessionIDs + ($0.sessionID.map { [$0] } ?? []) } ?? []
        past.removeAll { $0 == spec.sessionID }
        sessions[pane] = PaneSession(sessionID: spec.sessionID, pastSessionIDs: past, folder: sessions[pane]?.folder)
        launches[pane, default: 0] += 1
        return true
    }

    /// How many times the pane restarted. 0 for a pane that runs its first command.
    public func launch(of pane: PaneID) -> Int { launches[pane] ?? 0 }
}
