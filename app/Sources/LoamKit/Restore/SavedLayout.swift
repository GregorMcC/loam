import CoreGraphics
import Foundation

/// What `state.json` holds for restore (spec 8.5): the window, the active plot, each plot's tabs,
/// splits, and focused pane, and each pane's kind, session ID or shell folder, and done, unread flag.
///
/// It is 3 keys of the file. `AppStateFile` keeps the other keys (`switcher_use_times`,
/// `last_seen_changes`):
///
/// - `panes`: one object for each pane, open or saved and not yet resumed. `plot_id` and `folder`
///   are the shape that `loam worktree rm` reads (docs/contract.md, "Worktrees").
/// - `layout`: the active plot, and the tabs and splits of each plot. A tree leaf is a pane ID.
/// - `window`: the window frame, the sidebar, and the plot panel.
public struct SavedLayout: Codable, Equatable, Sendable {
    public struct Pane: Codable, Equatable, Sendable {
        public var id: PaneID
        public var plotID: String
        /// A shell pane's folder, or the folder where the session started. Nil when not known yet.
        public var folder: String?
        public var kind: PaneSpec.Kind
        /// The session that a seeded pane resumes. Nil for a shell pane.
        public var sessionID: String?
        /// The repo that a seeded pane named with `--repo`. Nil for the main repo.
        public var repo: String?
        /// The worktree that the pane runs in. Nil outside a worktree.
        public var worktree: WorktreeRef?
        /// True for a plot session (ticket 93). Nil in a layout saved before the field existed.
        public var plotFolder: Bool?
        public var doneUnread: Bool

        public init(id: PaneID, plotID: String, folder: String? = nil, kind: PaneSpec.Kind,
                    sessionID: String? = nil, repo: String? = nil, worktree: WorktreeRef? = nil,
                    plotFolder: Bool? = nil, doneUnread: Bool = false) {
            self.id = id
            self.plotID = plotID
            self.folder = folder
            self.kind = kind
            self.sessionID = sessionID
            self.repo = repo
            self.worktree = worktree
            self.plotFolder = plotFolder
            self.doneUnread = doneUnread
        }

        enum CodingKeys: String, CodingKey {
            case id, plotID = "plot_id", folder, kind, sessionID = "session_id", repo, worktree, plotFolder = "plot_folder",
                 doneUnread = "done_unread"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(PaneID.self, forKey: .id)
            plotID = try c.decode(String.self, forKey: .plotID)
            folder = try c.decodeIfPresent(String.self, forKey: .folder)
            kind = try c.decode(PaneSpec.Kind.self, forKey: .kind)
            sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
            repo = try c.decodeIfPresent(String.self, forKey: .repo)
            worktree = try c.decodeIfPresent(WorktreeRef.self, forKey: .worktree)
            plotFolder = try c.decodeIfPresent(Bool.self, forKey: .plotFolder)
            doneUnread = try c.decodeIfPresent(Bool.self, forKey: .doneUnread) ?? false
        }
    }

    public struct PlotTabs: Codable, Equatable, Sendable {
        public var tabs: [SavedTab]
        public var selected: Int
        public init(tabs: [SavedTab], selected: Int) { self.tabs = tabs; self.selected = selected }
    }

    public struct SavedTab: Codable, Equatable, Sendable {
        public var tree: SplitTree
        public var focused: PaneID
        public init(tree: SplitTree, focused: PaneID) { self.tree = tree; self.focused = focused }
    }

    public struct Layout: Codable, Equatable, Sendable {
        public var activePlot: String?
        public var plots: [String: PlotTabs]
        public init(activePlot: String? = nil, plots: [String: PlotTabs] = [:]) {
            self.activePlot = activePlot
            self.plots = plots
        }
        enum CodingKeys: String, CodingKey { case activePlot = "active_plot", plots }
    }

    public struct Window: Codable, Equatable, Sendable {
        /// x, y, width, and height in screen points. Nil before the window first moves or resizes.
        public var frame: [Double]?
        public var sidebarCollapsed: Bool
        public var panelOpen: Bool

        public init(frame: CGRect? = nil, sidebarCollapsed: Bool = false, panelOpen: Bool = false) {
            self.frame = frame.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) }
            self.sidebarCollapsed = sidebarCollapsed
            self.panelOpen = panelOpen
        }

        /// The frame as a rectangle. Nil when it is missing or has no size.
        public var rect: CGRect? {
            guard let f = frame, f.count == 4, f[2] > 0, f[3] > 0 else { return nil }
            return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }

        enum CodingKeys: String, CodingKey {
            case frame, sidebarCollapsed = "sidebar_collapsed", panelOpen = "panel_open"
        }
    }

    public var panes: [Pane]
    public var layout: Layout
    public var window: Window?

    public init(panes: [Pane] = [], layout: Layout = Layout(), window: Window? = nil) {
        self.panes = panes
        self.layout = layout
        self.window = window
    }

    // MARK: From a workspace

    /// The layout of the workspace. Each plot's panes are in tab order, then layout order. Plots
    /// sort by ID, so the same workspace always gives the same value.
    public init(workspace: Workspace, window: Window? = nil) {
        var panes: [Pane] = []
        var plots: [String: PlotTabs] = [:]
        for plot in workspace.plotIDsWithPanes.sorted() {
            let tabs = workspace.tabs(of: plot)
            plots[plot] = PlotTabs(tabs: tabs.map { SavedTab(tree: $0.tree, focused: $0.focused) },
                                   selected: workspace.selectedTabIndex(of: plot) ?? 0)
            for id in workspace.paneIDs(of: plot) {
                guard let spec = workspace.spec(of: id) else { continue }
                let session = workspace.session(of: id)
                panes.append(Pane(
                    id: id, plotID: plot, folder: workspace.folder(of: id), kind: spec.kind,
                    sessionID: spec.kind == .session ? (session?.sessionID ?? spec.sessionID) : nil,
                    repo: spec.repo, worktree: spec.worktree, plotFolder: spec.plotFolder,
                    doneUnread: session?.doneUnread ?? false))
            }
        }
        self.init(panes: panes, layout: Layout(activePlot: workspace.activePlotID, plots: plots), window: window)
    }

    // MARK: state.json

    static let panesKey = "panes"
    static let layoutKey = "layout"
    static let windowKey = "window"

    /// The 3 keys as JSON objects, for `AppStateFile.setValues`.
    public func jsonValues() throws -> [String: Any] {
        func object<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
        }
        return [
            Self.panesKey: try object(panes),
            Self.layoutKey: try object(layout),
            Self.windowKey: try window.map(object) ?? NSNull(),
        ]
    }

    /// Reads the layout from the file. A missing file gives an empty layout. A key that does not
    /// decode counts as missing, so a damaged layout restores no panes and the app still starts.
    public static func read(from file: AppStateFile) -> SavedLayout {
        func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            guard let raw = file.value(forKey: key), !(raw is NSNull),
                  let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        guard let panes = decode([Pane].self, panesKey), let layout = decode(Layout.self, layoutKey) else {
            return SavedLayout(window: decode(Window.self, windowKey))
        }
        return SavedLayout(panes: panes, layout: layout, window: decode(Window.self, windowKey))
    }
}

/// How a saved layout comes back after a launch (spec 8.5, ADR 0005). A pure step, so tests cover it.
///
/// - A session pane resumes its session with `loam resume`. A shell pane gets a fresh login shell
///   in its folder. The caller builds both specs.
/// - Each pane keeps its `PaneID`, so its switcher use time carries over.
/// - The panes of a plot that is gone are dropped. So is a leaf with no pane record.
/// - Every restored plot waits: its panes start when the plot is first shown. The active plot
///   shows at once when it is still in the plot list.
/// - Done, unread comes back. Needs you does not (it is not saved).
public struct RestorePlan: Sendable {
    public let workspace: Workspace
    /// Plots in the saved layout that are gone from the store.
    public let droppedPlots: [String]

    /// - Parameters:
    ///   - kept: the plot IDs that still exist, archived ones included. Archived plots keep their panes.
    ///   - shown: the plot IDs that can be active (the plot list without the archived plots).
    ///   - spec: the spec of a saved pane, or nil to drop it.
    public init(_ saved: SavedLayout, kept: Set<String>, shown: Set<String>,
                spec: (SavedLayout.Pane) -> PaneSpec?) {
        var records: [PaneID: SavedLayout.Pane] = [:]
        for pane in saved.panes where records[pane.id] == nil { records[pane.id] = pane }
        var workspace = Workspace()
        var used: Set<PaneID> = []
        var dropped: [String] = []
        for (plot, saved) in saved.layout.plots.sorted(by: { $0.key < $1.key }) {
            guard kept.contains(plot) else { dropped.append(plot); continue }
            var specs: [PaneID: PaneSpec] = [:]
            var sessions: [PaneID: PaneSession] = [:]
            var tabs: [Tab] = []
            var selected = saved.selected
            for (index, tab) in saved.tabs.enumerated() {
                var tree: SplitTree? = tab.tree
                for id in tab.tree.paneIDs {
                    guard !used.contains(id), let record = records[id], record.plotID == plot,
                          var paneSpec = spec(record) else {
                        tree = tree?.removing(id)
                        continue
                    }
                    paneSpec.plot = plot
                    used.insert(id)
                    specs[id] = paneSpec
                    sessions[id] = PaneSession(sessionID: paneSpec.sessionID, folder: record.folder,
                                               doneUnread: record.doneUnread)
                }
                guard let tree else {
                    if index < saved.selected { selected -= 1 }
                    continue
                }
                let focused = tree.contains(tab.focused) ? tab.focused : tree.paneIDs[0]
                tabs.append(Tab(id: UUID(), tree: tree, focused: focused))
            }
            workspace.restorePlot(plot, tabs: tabs, selected: selected, specs: specs, sessions: sessions)
        }
        if let active = saved.layout.activePlot, shown.contains(active) { workspace.activate(plot: active) }
        self.workspace = workspace
        droppedPlots = dropped
    }
}
