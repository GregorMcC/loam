import CoreGraphics
import Foundation

/// What `state.json` holds for restore (spec 8.5): the window, the active space, the tabs, splits,
/// and focused pane of Home and of each plot, and each pane's kind, session ID or shell folder, and
/// done, unread flag.
///
/// It is 3 keys of the file. `AppStateFile` keeps the other keys (`switcher_use_times`,
/// `last_seen_changes`):
///
/// - `panes`: one object for each pane, open or saved and not yet resumed. `plot_id` and `folder`
///   are the shape that `loam worktree rm` reads (docs/contract.md, "Worktrees").
/// - `layout`: the active space, and the tabs and splits of Home and of each plot. A tree leaf is a
///   pane ID.
/// - `window`: the window frame, the sidebar, and the plot panel.
///
/// Home (ticket 99) is in keys that a build before Home ignores, so that build keeps the plot panes:
/// a Home pane has `"home": true` and an empty `plot_id`, which matches no plot. The Home tabs are
/// in `layout.home`, and `layout.active_home` is true when Home is active. That build does not
/// write these keys back, so after a downgrade the Home tabs are gone at its first save.
public struct SavedLayout: Codable, Equatable, Sendable {
    public struct Pane: Codable, Equatable, Sendable {
        public var id: PaneID
        public var space: Space
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

        public init(id: PaneID, space: Space, folder: String? = nil, kind: PaneSpec.Kind,
                    sessionID: String? = nil, repo: String? = nil, worktree: WorktreeRef? = nil,
                    plotFolder: Bool? = nil, doneUnread: Bool = false) {
            self.id = id
            self.space = space
            self.folder = folder
            self.kind = kind
            self.sessionID = sessionID
            self.repo = repo
            self.worktree = worktree
            self.plotFolder = plotFolder
            self.doneUnread = doneUnread
        }

        enum CodingKeys: String, CodingKey {
            case id, plotID = "plot_id", home, folder, kind, sessionID = "session_id", repo, worktree, plotFolder = "plot_folder",
                 doneUnread = "done_unread"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(PaneID.self, forKey: .id)
            space = try c.decodeIfPresent(Bool.self, forKey: .home) == true ? .home : .plot(c.decode(String.self, forKey: .plotID))
            folder = try c.decodeIfPresent(String.self, forKey: .folder)
            kind = try c.decode(PaneSpec.Kind.self, forKey: .kind)
            sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
            repo = try c.decodeIfPresent(String.self, forKey: .repo)
            worktree = try c.decodeIfPresent(WorktreeRef.self, forKey: .worktree)
            plotFolder = try c.decodeIfPresent(Bool.self, forKey: .plotFolder)
            doneUnread = try c.decodeIfPresent(Bool.self, forKey: .doneUnread) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(space.plotID ?? "", forKey: .plotID)
            if space.isHome { try c.encode(true, forKey: .home) }
            try c.encodeIfPresent(folder, forKey: .folder)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(sessionID, forKey: .sessionID)
            try c.encodeIfPresent(repo, forKey: .repo)
            try c.encodeIfPresent(worktree, forKey: .worktree)
            try c.encodeIfPresent(plotFolder, forKey: .plotFolder)
            try c.encode(doneUnread, forKey: .doneUnread)
        }
    }

    public struct SpaceTabs: Codable, Equatable, Sendable {
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
        /// True when Home is active. Nil otherwise, so the key is left out.
        public var activeHome: Bool?
        public var plots: [String: SpaceTabs]
        /// The tabs of Home. Nil when Home has none.
        public var home: SpaceTabs?

        public init(active: Space? = nil, plots: [String: SpaceTabs] = [:], home: SpaceTabs? = nil) {
            self.activePlot = active?.plotID
            self.activeHome = active?.isHome == true ? true : nil
            self.plots = plots
            self.home = home
        }

        /// The active space.
        public var active: Space? { activeHome == true ? .home : activePlot.map(Space.plot) }

        /// The saved tabs of each space, Home first, then the plots by ID.
        public var spaces: [(space: Space, tabs: SpaceTabs)] {
            let plotTabs = plots.map { (space: Space.plot($0.key), tabs: $0.value) }
            return (home.map { [(space: Space.home, tabs: $0)] } ?? []) + plotTabs.sorted { $0.space < $1.space }
        }

        enum CodingKeys: String, CodingKey { case activePlot = "active_plot", activeHome = "active_home", plots, home }
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

    /// The layout of the workspace. Each space's panes are in tab order, then layout order. Home
    /// comes first, then the plots by ID, so the same workspace always gives the same value.
    public init(workspace: Workspace, window: Window? = nil) {
        var panes: [Pane] = []
        var layout = Layout(active: workspace.activeSpace)
        for space in workspace.spacesWithPanes.sorted() {
            let tabs = SpaceTabs(tabs: workspace.tabs(of: space).map { SavedTab(tree: $0.tree, focused: $0.focused) },
                                 selected: workspace.selectedTabIndex(of: space) ?? 0)
            switch space {
            case .home: layout.home = tabs
            case .plot(let id): layout.plots[id] = tabs
            }
            for id in workspace.paneIDs(of: space) {
                guard let spec = workspace.spec(of: id) else { continue }
                let session = workspace.session(of: id)
                panes.append(Pane(
                    id: id, space: space, folder: workspace.folder(of: id), kind: spec.kind,
                    sessionID: spec.kind == .session ? (session?.sessionID ?? spec.sessionID) : nil,
                    repo: spec.repo, worktree: spec.worktree, plotFolder: spec.plotFolder,
                    doneUnread: session?.doneUnread ?? false))
            }
        }
        self.init(panes: panes, layout: layout, window: window)
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
/// - The panes of a plot that is gone are dropped. So is a leaf with no pane record. Home is never gone.
/// - Every restored space waits: its panes start when the space is first shown. The active space
///   shows at once when it is Home or a plot still in the plot list.
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
        for (space, saved) in saved.layout.spaces {
            if let plot = space.plotID, !kept.contains(plot) { dropped.append(plot); continue }
            var specs: [PaneID: PaneSpec] = [:]
            var sessions: [PaneID: PaneSession] = [:]
            var tabs: [Tab] = []
            var selected = saved.selected
            for (index, tab) in saved.tabs.enumerated() {
                var tree: SplitTree? = tab.tree
                for id in tab.tree.paneIDs {
                    guard !used.contains(id), let record = records[id], record.space == space,
                          var paneSpec = spec(record) else {
                        tree = tree?.removing(id)
                        continue
                    }
                    paneSpec.space = space
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
            workspace.restore(space, tabs: tabs, selected: selected, specs: specs, sessions: sessions)
        }
        switch saved.layout.active {
        case .home: workspace.activate(.home)
        case .plot(let id) where shown.contains(id): workspace.activate(.plot(id))
        default: break
        }
        self.workspace = workspace
        droppedPlots = dropped
    }
}
