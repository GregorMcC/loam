import CoreGraphics
import Foundation
import Observation

/// The app's state: the plots from the core, the workspace of tabs and splits, and the sidebar flag.
/// Every plot read and write goes through `LoamClient`. Views and the window controller read it.
@MainActor
@Observable
public final class AppModel {
    public let client: LoamClient
    /// The settings file and the settings window (ticket 81).
    public let settings: SettingsModel
    /// What the settings window shows about the Ghostty config. The terminal runtime fills it.
    public let terminalConfig = TerminalConfigModel()
    public private(set) var plots: [PlotSummary] = [] { didSet { if plots != oldValue { onWorkspaceChange?() } } }
    /// Archived plots. They leave the sidebar but keep their panes (spec section 10).
    public private(set) var archivedPlots: [PlotSummary] = []
    /// The tabs, splits, and pane sessions. Each change also clears done, unread of the pane that you
    /// look at (spec 8.4), so a turn that ends in front of you is never unread.
    public private(set) var workspace: Workspace {
        get { storedWorkspace }
        set {
            var next = newValue
            if isFrontmost(), let pane = next.focusedPane { next.markSeen(pane) }
            storedWorkspace = next
        }
    }
    private var storedWorkspace = Workspace() {
        didSet {
            guard storedWorkspace != oldValue else { return }
            if !terminalTitles.isEmpty {
                let live = Set(storedWorkspace.allPaneIDs)
                terminalTitles = terminalTitles.filter { live.contains($0.key) }
            }
            attentionChanged()
            onWorkspaceChange?()
            saveLayout()
        }
    }
    /// The worktrees of each plot with their checks, as the core last listed them.
    public private(set) var worktrees: [String: [WorktreeStatus]] = [:] { didSet { if worktrees != oldValue { onWorkspaceChange?() } } }
    /// Panes that were saved and have not resumed, as folders. Removal refuses while one lies in the
    /// worktree. The default reads the restored panes that wait for their plot to show (ticket 29).
    @ObservationIgnored private var worktreeReads = 0
    /// The plot list read that runs now, and the calls asked and served (`reloadPlots`).
    @ObservationIgnored private var plotRead: Task<Void, Never>?
    @ObservationIgnored private var plotReadsWanted = 0
    @ObservationIgnored private var plotReadsDone = 0
    @ObservationIgnored public var savedPaneFolders: () -> [String] = { [] }
    public var sidebarCollapsed = false { didSet { onWorkspaceChange?(); saveLayout() } }
    /// The last core error, in words for a person. The window shows it.
    public var lastError: String?
    /// Set when the launch check fails. The window shows it and loads nothing else.
    public private(set) var launchBlock: String?
    /// The setup steps that are not done. A non-empty list shows the setup banner.
    public private(set) var setupSteps: [SetupStep] = []

    /// The plot panel's model. It loads the active plot only while the panel shows.
    @ObservationIgnored public let panel: PlotPanelModel
    /// Review and undo: the change log, the "New since you looked" box, and the counts.
    public let review: ReviewModel

    /// The quick switcher (⌘P).
    @ObservationIgnored public let switcher = SwitcherModel()
    /// Use times for the switcher. The app sets it; tests leave it nil, so they never write `state.json`.
    @ObservationIgnored public var useTimes: UseTimes? { didSet { switcher.useTimes = useTimes } }
    /// The title libghostty reports for each pane. The switcher matches on it, and the sidebar and
    /// the tab bar show it (ticket 71).
    public private(set) var terminalTitles: [PaneID: String] = [:]
    /// The repos of each plot with their branches, main repo first (tickets 71 and 76). Each one is a
    /// row in the sidebar tree. A plot with no repos has no entry.
    public private(set) var repoCheckouts: [String: [RepoCheckout]] = [:]
    /// The label of each plot's main checkout: the main repo's branch, or its folder name when the
    /// folder is not a git checkout. A plot with no main repo has no entry.
    public var mainCheckouts: [String: String] {
        repoCheckouts.compactMapValues { $0.first(where: \.isMain)?.label }
    }
    /// The repos of each plot, main repo first, from the last export. Their branches are not read yet.
    @ObservationIgnored private var repoPaths: [String: [RepoCheckout]] = [:]
    /// Counts the exports, so only the newest one applies.
    @ObservationIgnored private var mainRepoReads = 0
    /// One branch read runs at a time. A request while it runs asks for one more read after it, so
    /// a burst of git events makes two reads at most.
    @ObservationIgnored private var branchReadRunning = false
    @ObservationIgnored private var branchReadAgain = false

    @ObservationIgnored public var onWorkspaceChange: (() -> Void)?
    /// A terminal title changed. The window redraws the tab labels. Calls come at most once per main
    /// run loop pass, so a pane that sets its title in a loop costs one redraw a pass.
    @ObservationIgnored public var onTitleChange: (() -> Void)?
    @ObservationIgnored private var titleChangePending = false
    @ObservationIgnored private var feedTask: Task<Void, Never>?

    // MARK: Restore (spec 8.5)

    /// Writes the layout to `state.json`. Set by `startRestore(from:)`. Tests that leave it nil write nothing.
    @ObservationIgnored public private(set) var stateWriter: AppStateWriter?
    /// The saved layout, until the first plot list arrives. No layout write happens before that,
    /// so a launch that fails to read the plots keeps the saved panes.
    @ObservationIgnored private var pendingRestore: SavedLayout?
    /// The window part of the saved layout. The window reads it once when it opens.
    @ObservationIgnored public private(set) var restoredWindow: SavedLayout.Window?
    /// The window frame. The window sets it after a move or a resize.
    @ObservationIgnored public var windowFrame: CGRect? { didSet { if windowFrame != oldValue { saveLayout() } } }

    public init(client: LoamClient = LoamClient(), stateFile: AppStateFile = AppStateFile(),
                settingsFile: SettingsFile? = nil) {
        self.client = client
        // The file is in the client's LOAM_HOME, so a test store has its own settings.
        self.settings = SettingsModel(file: settingsFile ?? SettingsFile(environment: client.environment),
                                      launchBinary: client.binary.path)
        self.panel = PlotPanelModel(client: client)
        panel.suggestionRoots = settings.repoFolderPaths
        self.review = ReviewModel(client: client, state: stateFile)
        review.onUndone = { [weak self] in await self?.reloadPanel() }
        switcher.app = self
        review.paneLookup = { [weak self] in self?.paneRef(forSession: $0) }
        review.onGoToPane = { [weak self] in self?.goToPane($0.id) }
        switcher.attention = { [weak self] in self?.workspace.attention(of: $0) ?? .none }
        savedPaneFolders = { [weak self] in
            guard let ws = self?.workspace else { return [] }
            return ws.waitingPaneIDs.compactMap(ws.folder(of:))
        }
        settings.onChange = { [weak self] _ in
            guard let self else { return }
            panel.suggestionRoots = settings.repoFolderPaths
        }
    }

    public var sidebar: SidebarModel {
        SidebarModel(
            plots: plots, workspace: workspace, collapsed: sidebarCollapsed,
            newChangeCounts: review.sidebarCounts(activePlot: workspace.activePlotID), worktrees: worktrees,
            arriving: arrivingPanes(), repos: repoCheckouts, titles: terminalTitles)
    }

    /// ⌘I. Closing the panel marks the changes of the active plot as seen.
    public func setPanelVisible(_ show: Bool) {
        if panel.visible, !show { review.markSeen(plot: workspace.activePlotID) }
        panel.visible = show
        saveLayout()
    }

    /// Reads the saved layout and starts the layout writes. The window and the panes come back
    /// when the first plot list arrives (`apply`). Call it before the window opens.
    /// `writeDelay` is the longest time a change waits for its write; tests make it short.
    public func startRestore(from file: AppStateFile, writeDelay: Duration = .seconds(1)) {
        let saved = SavedLayout.read(from: file)
        pendingRestore = saved
        restoredWindow = saved.window
        let writer = AppStateWriter(file: file, delay: writeDelay)
        writer.layout = { [weak self] in self?.savedLayout }
        stateWriter = writer
    }

    /// The layout as `state.json` holds it.
    public var savedLayout: SavedLayout {
        SavedLayout(workspace: workspace, window: SavedLayout.Window(
            frame: windowFrame, sidebarCollapsed: sidebarCollapsed, panelOpen: panel.visible))
    }

    /// Marks the layout as changed. The writer builds it at its next write, at most once a second.
    private func saveLayout() {
        guard pendingRestore == nil else { return }
        stateWriter?.setLayoutChanged()
    }

    /// The spec that brings a saved pane back: `loam resume` for a session, a fresh login shell
    /// in the same folder for a shell. A session pane with no session ID is dropped.
    func restoreSpec(_ pane: SavedLayout.Pane) -> PaneSpec? {
        switch pane.kind {
        case .session: pane.sessionID.map {
            resumeSpec(in: pane.plotID, sessionID: $0, repo: pane.repo, worktree: pane.worktree,
                       plotFolder: pane.plotFolder ?? false)
        }
        case .shell: newShellSpec(in: pane.plotID, folder: pane.folder, worktree: pane.worktree)
        }
    }

    /// At quit, before the panes close: the last layout write, then no more writes, so the closes
    /// keep every pane in `state.json`. The changes in an open panel count as seen (ticket 36),
    /// and the panel stays open in the saved layout.
    public func prepareForQuit() {
        saveLayout()
        stateWriter?.suspend()
        if panel.visible { review.markSeen(plot: workspace.activePlotID) }
    }

    // MARK: Launch

    /// The launch check (ADR 0004). A contract mismatch (or a missing binary) sets `launchBlock`
    /// and loads nothing. Otherwise it keeps the pending setup steps for the banner,
    /// loads the plots, and starts the feed.
    public func launch(startFeed shouldStartFeed: Bool = true) async {
        if shouldStartFeed { settings.startWatching() }
        switch await LaunchCheck.run(client: client) {
        case .blocked(let message):
            launchBlock = message
        case .ready(let steps):
            launchBlock = nil
            setupSteps = steps
            await reloadPlots()
            await review.reload()
            await reloadWorktrees()
            if shouldStartFeed { startFeed() }
        }
    }

    // MARK: Plots from the core

    /// Reads the plot list and the archived list. Keeps the active plot when it still exists,
    /// keeps the tabs of archived plots, and drops the tabs of deleted plots.
    /// A failed read changes nothing, so a failed archived read cannot look like a delete.
    /// One read runs at a time, so an older list never replaces a newer one (ticket 61). A call
    /// returns after a read that started after the call has applied. The calls that come while a
    /// read runs share the one read that follows it.
    public func reloadPlots() async {
        plotReadsWanted += 1
        let wanted = plotReadsWanted
        while plotReadsDone < wanted {
            if let running = plotRead {
                await running.value
                continue
            }
            let target = plotReadsWanted
            plotRead = Task { [weak self] in
                guard let self else { return }
                await self.readPlots()
                self.plotReadsDone = max(self.plotReadsDone, target)
                self.plotRead = nil
            }
        }
    }

    private func readPlots() async {
        do {
            var list = try await client.list()
            var archived = try await client.listArchived()
            // An archive or unarchive between the two reads can hide a plot from both lists, and
            // `apply` then drops its panes. A plot with panes counts as deleted only when a second
            // read also misses it.
            let seen = Set((list + archived).map(\.id))
            if workspace.plotIDsWithPanes.contains(where: { !seen.contains($0) }) {
                list = try await client.list()
                archived = try await client.listArchived()
            }
            apply(list, archived: archived)
            lastError = nil
            await reloadPanel()
        } catch {
            report(error)
        }
    }

    /// Reads the worktrees of every plot. A failed read keeps the last list.
    public func reloadWorktrees() async {
        worktreeReads += 1
        let mine = worktreeReads
        guard let all = try? await client.worktrees(), mine == worktreeReads else { return }  // A newer read wins.
        worktrees = Dictionary(grouping: all, by: { $0.worktree.plotID })
    }

    /// Reads the repos of every plot (`loam export`), then the branch of each one off the main
    /// thread. A failed read keeps the last labels. A newer read wins. The sidebar calls it when the
    /// plot list moves or a change edits a repo (a repo add or a new main repo).
    public func reloadMainCheckouts() async {
        mainRepoReads += 1
        let mine = mainRepoReads
        guard let export = try? await client.export(), mine == mainRepoReads else { return }
        repoPaths = export.plots.reduce(into: [String: [RepoCheckout]]()) { all, plot in
            guard !plot.repos.isEmpty else { return }
            all[plot.id] = (plot.repos.filter(\.main) + plot.repos.filter { !$0.main }).map {
                RepoCheckout(id: $0.id, path: $0.path, isMain: $0.main)
            }
        }
        await rereadMainCheckoutBranches()
    }

    /// Reads the branch of each known repo again, off the main thread, and runs no `loam`. The
    /// window calls it when a `HEAD` changes or the active plot's repo changes, so the repo rows
    /// follow a checkout. A call while a read runs returns at once, and the running read reads
    /// again when it ends.
    public func rereadMainCheckoutBranches() async {
        guard !branchReadRunning else { branchReadAgain = true; return }
        branchReadRunning = true
        defer { branchReadRunning = false }
        repeat {
            branchReadAgain = false
            let repos = repoPaths
            let read = await Task.detached {
                repos.mapValues { list in
                    list.map { repo in
                        var repo = repo
                        repo.branch = RepoLine(path: repo.path).branch
                        return repo
                    }
                }
            }.value
            // A request came in while this read ran: its result is old, so read again.
            if !branchReadAgain, read != repoCheckouts { repoCheckouts = read }
        } while branchReadAgain
    }

    /// Loads the active plot into the panel when the panel shows.
    public func reloadPanel() async {
        guard panel.visible else { return }
        await panel.load(plotID: workspace.activePlotID)
    }

    private func report(_ error: Error) {
        lastError = (error as? LoamError)?.userMessage ?? String(describing: error)
    }

    public func apply(_ list: [PlotSummary], archived: [PlotSummary] = []) {
        // A read that lands while `loam move` runs keeps the order that the sidebar shows (ticket 98).
        plots = pendingPlotOrder.map { Self.sorted(list, by: $0) } ?? list
        archivedPlots = archived
        let ids = Set(list.map(\.id))
        var next = workspace
        let kept = ids.union(archived.map(\.id))
        if let saved = pendingRestore {
            next = RestorePlan(saved, kept: kept, shown: ids, spec: restoreSpec).workspace
            pendingRestore = nil
        }
        for gone in Set(next.plotIDsWithPanes).subtracting(kept) { next.removePlot(gone) }
        if next.activePlotID.map(ids.contains) != true {
            next.activate(plot: list.first?.id)
        }
        workspace = next
    }

    /// Reloads the plot list on every feed update, for the life of the model.
    /// `move`, `archive`, `unarchive`, and `delete` write no new change, so every update counts.
    public func startFeed(feed: ChangeFeed? = nil) {
        feedTask?.cancel()
        let feed = feed ?? ChangeFeed(client: client)
        feedTask = Task { [weak self] in
            for await update in feed.updates() {
                guard let self, !Task.isCancelled else { return }
                if case .failure = update { continue }
                await self.reloadPlots()
                await self.review.reload()
                await self.reloadWorktrees()
            }
        }
    }

    public func stopFeed() { feedTask?.cancel() }

    /// `loam new --json`, then the new plot becomes active.
    public func newPlot(named name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let plot = try await client.new(name: name)
            await reloadPlots()
            activate(plot: plot.id)
        } catch {
            report(error)
        }
    }

    /// A drag in the sidebar drops `moving` at `slot` of its section (ticket 98): `showPlotMove`, then
    /// `storePlotMove`.
    public func movePlot(_ moving: String, toSlot slot: Int) async {
        guard let move = showPlotMove(moving, toSlot: slot) else { return }
        await storePlotMove(move)
    }

    /// A plot move that the sidebar shows and the store does not have yet.
    public struct PlotMove: Sendable {
        let plot: String
        let slot: Int
        /// The sidebar order before the move.
        let shown: [String]
        let sidebar: SidebarModel
    }

    /// The sidebar shows the new order at once, and a plot list read keeps it until `storePlotMove`
    /// ends. Nil when nothing moves, or while another move runs.
    public func showPlotMove(_ moving: String, toSlot slot: Int) -> PlotMove? {
        let shown = plots.map(\.id)
        let sidebar = self.sidebar
        guard pendingPlotOrder == nil, let next = sidebar.order(moving: moving, toSlot: slot, in: shown) else { return nil }
        pendingPlotOrder = next
        plots = Self.sorted(plots, by: next)
        return PlotMove(plot: moving, slot: slot, shown: shown, sidebar: sidebar)
    }

    /// `loam move`, then a reload. The store order also holds the archived plots, so with any
    /// archived plot the position comes from `loam export`. A failure puts the plot back and sets `lastError`.
    public func storePlotMove(_ move: PlotMove) async {
        do {
            let full = archivedPlots.isEmpty ? move.shown : try await client.export().plots.map(\.id)
            if let position = move.sidebar.movePosition(moving: move.plot, toSlot: move.slot, in: full) {
                _ = try await client.move(plot: move.plot, position: position)
            }
            // A read that started before the move still lands with the old order, so the new order
            // holds until a read that started after it.
            await reloadPlots()
            pendingPlotOrder = nil
        } catch {
            pendingPlotOrder = nil
            plots = Self.sorted(plots, by: move.shown)
            report(error)
        }
    }

    /// The order that the sidebar shows while `loam move` runs. Nil when no move runs.
    @ObservationIgnored private var pendingPlotOrder: [String]?

    /// True while a plot move is shown and not yet stored. The sidebar starts no new drag then.
    public var isMovingPlot: Bool { pendingPlotOrder != nil }

    /// The plots in `order`. A plot that `order` does not name keeps its place after the named ones.
    private static func sorted(_ list: [PlotSummary], by order: [String]) -> [PlotSummary] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }) { first, _ in first }
        func key(_ offset: Int, _ plot: PlotSummary) -> Int { rank[plot.id] ?? order.count + offset }
        return list.enumerated().sorted { key($0.offset, $0.element) < key($1.offset, $1.element) }.map(\.element)
    }

    // MARK: Plot selection

    public func activate(plot id: String) {
        guard plots.contains(where: { $0.id == id }) else { return }
        // A switch with the panel open marks the plot that you leave as seen.
        if panel.visible, id != workspace.activePlotID { review.markSeen(plot: workspace.activePlotID) }
        workspace.activate(plot: id)
        useTimes?.record(SwitcherItem.plotKey(id))
        if panel.visible { Task { await reloadPanel() } }
    }

    public func activate(number: Int) {
        if let id = sidebar.plotID(forNumber: number) { activate(plot: id) }
    }

    // MARK: Pane specs

    /// The login shell that runs a seeded pane's command. Tests set it.
    @ObservationIgnored public var shell = PaneCommand.userShell()

    /// The plot folder: `<Loam home>/plots/<id>`, as the core keeps it.
    public func plotFolder(_ plot: String) -> String {
        DirectoryWatcher.home(environment: client.environment).appendingPathComponent("plots/\(plot)").path
    }

    /// Where a shell pane of the plot starts (spec 8.2): the main repo, or the plot folder when the
    /// plot has no repos. A failed read gives the plot folder.
    public func startFolder(of plot: String) async -> String {
        let main = try? await client.show(plot: plot).repos.first(where: \.main)?.path
        return main ?? plotFolder(plot)
    }

    /// A seeded session: `loam start` with a new session ID. The pane gets the client's environment,
    /// so it talks to the same store as the app.
    /// With `worktree`, the command is `loam start <plot> --worktree <id> ...`.
    public func newSessionSpec(in plot: String, repo: String? = nil, worktree: WorktreeRef? = nil,
                               plotFolder: Bool = false) -> PaneSpec {
        let id = UUID().uuidString.lowercased()
        let command = PaneCommand.start(shell: shell, loam: client.binary.path, plot: plot, repo: repo,
                                        worktree: worktree?.id, plotFolder: plotFolder, sessionID: id)
        var spec = PaneSpec(kind: .session, plot: plot, command: command, env: client.environment,
                            title: "claude", repo: repo, sessionID: id, worktree: worktree)
        spec.inPlotFolder = plotFolder
        return spec
    }

    /// Opens a plot session (ticket 93): a seeded session in the plot folder, with every repo as an
    /// added folder. It makes the plot active first.
    public func openPlotSession(_ plot: String) {
        if workspace.activePlotID != plot { activate(plot: plot) }
        guard workspace.activePlotID == plot else { return }
        workspace.openTab(newSessionSpec(in: plot, plotFolder: true))
    }

    /// `loam resume` of a session in the plot. The core resumes in the worktree, or fails if it is gone.
    /// `plotFolder` marks a plot session (ticket 93). `loam resume` finds the folder from the record.
    public func resumeSpec(in plot: String, sessionID: String, repo: String? = nil, worktree: WorktreeRef? = nil,
                           plotFolder: Bool = false) -> PaneSpec {
        let command = PaneCommand.resume(shell: shell, loam: client.binary.path, sessionID: sessionID)
        var spec = PaneSpec(kind: .session, plot: plot, command: command, env: client.environment,
                            title: "claude", repo: repo, sessionID: sessionID, worktree: worktree)
        spec.inPlotFolder = plotFolder
        return spec
    }

    /// A login shell. `folder` nil starts it in your home folder. A worktree sets the folder.
    public func newShellSpec(in plot: String, folder: String? = nil, worktree: WorktreeRef? = nil) -> PaneSpec {
        PaneSpec(kind: .shell, plot: plot, folder: worktree?.path ?? folder, env: client.environment, title: "shell",
                 worktree: worktree)
    }

    private func spec(_ kind: PaneSpec.Kind, in plot: String, folder: String?, repo: String? = nil,
                      worktree: WorktreeRef? = nil) -> PaneSpec {
        kind == .session ? newSessionSpec(in: plot, repo: repo, worktree: worktree)
                         : newShellSpec(in: plot, folder: folder, worktree: worktree)
    }

    // MARK: Tabs and splits of the active plot

    /// Opens a tab in the active plot. ⌘T opens a seeded session. `repo` picks a repo other than the
    /// main repo for a session, and `folder` the start folder of a shell.
    public func openTab(_ kind: PaneSpec.Kind = .shell, folder: String? = nil, repo: String? = nil,
                        worktree: WorktreeRef? = nil) {
        guard let plot = workspace.activePlotID else { return }
        workspace.openTab(spec(kind, in: plot, folder: folder, repo: repo, worktree: worktree))
    }

    /// ⌘D and ⌘⇧D split with a seeded session. A shell split comes from the menu or ⌘J.
    public func split(_ axis: SplitAxis, _ kind: PaneSpec.Kind = .shell, folder: String? = nil) {
        guard let plot = workspace.activePlotID else { return }
        workspace.split(plot: plot, axis: axis, spec(kind, in: plot, folder: folder))
    }

    /// ⌘⌥T: a shell tab in the plot's start folder. The plot is the one active at the call.
    public func openShellTab() async {
        guard let plot = workspace.activePlotID else { return }
        let folder = await startFolder(of: plot)
        guard workspace.activePlotID == plot else { return }
        openTab(.shell, folder: folder)
    }

    /// A shell split in the plot's start folder.
    public func splitShell(_ axis: SplitAxis) async {
        guard let plot = workspace.activePlotID else { return }
        let folder = await startFolder(of: plot)
        guard workspace.activePlotID == plot else { return }
        split(axis, .shell, folder: folder)
    }

    // MARK: Sessions in panes

    /// A line from the pane's socket.
    public func apply(_ event: PaneEvent, to pane: PaneID) {
        workspace.apply(event, to: pane)
    }

    // MARK: Attention (spec 8.4)

    /// True while Loam is the frontmost app. The app reads `NSApp.isActive`. Tests and the driver set it.
    @ObservationIgnored public var isFrontmost: () -> Bool = { true }
    /// The macOS banner and the Dock badge. The app sets the system notifier. Nil shows nothing.
    @ObservationIgnored public var notifier: AttentionNotifier? {
        didSet { notifier?.setBadge(needsYouSince.count) }
    }
    /// When each pane that needs you started to need you, for the halo.
    @ObservationIgnored private var needsYouSince: [PaneID: Date] = [:]
    /// The halo runs 3 cycles of `duration-halo`. After this time a mark no longer counts as arriving.
    public static let arrivalWindow = Double(LoamMotion.haloCycles) * LoamTheme.durationHalo

    /// You typed in the pane. Needs you clears, because a denied prompt sends no hook.
    public func typed(in pane: PaneID) {
        guard workspace.state(of: pane) == .needsYou else { return }
        workspace.typed(in: pane)
    }

    /// Loam became frontmost or stopped being frontmost. Done, unread of the pane that you see clears.
    public func frontmostChanged() {
        guard isFrontmost(), let pane = workspace.focusedPane, workspace.session(of: pane)?.doneUnread == true else { return }
        workspace.markSeen(pane)
    }

    /// The panes that need you, in sidebar order: plot order, then tab order, then layout order.
    public var needsYouPanes: [PaneID] {
        plots.flatMap { workspace.paneIDs(of: $0.id) }.filter { workspace.state(of: $0) == .needsYou }
    }

    /// The panes that need you in plots other than the active one. The title bar button counts them.
    public var elsewhereNeedYouCount: Int {
        needsYouPanes.filter { workspace.spec(of: $0)?.plot != workspace.activePlotID }.count
    }

    /// ⌘L: the next pane that needs you after the focused pane, in sidebar order, round to the start.
    /// `elsewhere` skips the panes of the active plot (the title bar button). Nil when there is none.
    public func nextPaneThatNeedsYou(elsewhere: Bool = false) -> PaneID? {
        let waiting = Set(needsYouPanes.filter { !elsewhere || workspace.spec(of: $0)?.plot != workspace.activePlotID })
        return AttentionCycle.next(order: plots.flatMap { workspace.paneIDs(of: $0.id) }, matching: waiting,
                                   after: workspace.focusedPane)
    }

    /// The next pane that is done, unread, by the same rule as `nextPaneThatNeedsYou`.
    public func nextPaneDoneUnread() -> PaneID? {
        let order = plots.flatMap { workspace.paneIDs(of: $0.id) }
        return AttentionCycle.next(order: order, matching: Set(order.filter { workspace.attention(of: $0) == .doneUnread }),
                                   after: workspace.focusedPane)
    }

    /// A click on a fixed attention row of the sidebar: goes to the next pane in that state, across plots.
    /// It does nothing for another state or when no pane is in the state.
    public func goToNextPane(in attention: PaneAttention) {
        let pane = switch attention {
        case .needsYou: nextPaneThatNeedsYou()
        case .doneUnread: nextPaneDoneUnread()
        case .none: nil as PaneID?
        }
        if let pane { goToPane(pane) }
    }

    /// ⌘L: makes the next pane that needs you active and focused. Returns false when no other pane needs you.
    @discardableResult
    public func goToNextPaneThatNeedsYou(elsewhere: Bool = false) -> Bool {
        guard let pane = nextPaneThatNeedsYou(elsewhere: elsewhere), pane != workspace.focusedPane else { return false }
        goToPane(pane)
        return true
    }

    /// The panes that started to need you less than `arrivalWindow` ago. Their dots play the halo.
    public func arrivingPanes(at now: Date = Date()) -> Set<PaneID> {
        Set(needsYouSince.filter { now.timeIntervalSince($0.value) < Self.arrivalWindow }.keys)
    }

    /// Keeps the arrival times, the banners, and the Dock badge in step with the workspace.
    private func attentionChanged() {
        let now = Date()
        var arrived: [PaneID] = []
        for pane in workspace.allPaneIDs where workspace.state(of: pane) == .needsYou && needsYouSince[pane] == nil {
            needsYouSince[pane] = now
            arrived.append(pane)
        }
        let cleared = needsYouSince.keys.filter { workspace.state(of: $0) != .needsYou }
        for pane in cleared { needsYouSince[pane] = nil }
        guard let notifier, !arrived.isEmpty || !cleared.isEmpty else { return }
        if !cleared.isEmpty { notifier.remove(cleared) }
        if !isFrontmost() {
            for pane in arrived { notifier.post(banner(for: pane)) }
        }
        notifier.setBadge(needsYouSince.count)
    }

    private func banner(for pane: PaneID) -> AttentionBanner {
        let spec = workspace.spec(of: pane)
        let plotName = plots.first { $0.id == spec?.plot }?.name ?? ""
        return AttentionBanner(pane: pane, plotName: plotName, paneTitle: workspace.title(of: pane, terminalTitles: terminalTitles),
                               reason: workspace.session(of: pane)?.waitsOn)
    }

    /// The pane's process exited. A seeded pane stays and shows "Session ended".
    public func paneExited(_ pane: PaneID) {
        workspace.processExited(pane)
        // A worktree pane that ends may have lost its folder. Read the list again for the ended note.
        if workspace.spec(of: pane)?.worktree != nil { Task { await reloadWorktrees() } }
    }

    /// "Session ended", Resume: `loam resume` of the pane's last session, in the same place.
    /// Nothing happens while the process runs, or when no session started in the pane.
    public func resumeSession(in pane: PaneID) {
        guard let spec = workspace.spec(of: pane), spec.kind == .session,
              let session = workspace.session(of: pane), session.exited, session.started,
              let id = session.sessionID else { return }
        workspace.restartPane(pane, with: resumeSpec(in: spec.plot, sessionID: id, repo: spec.repo, worktree: spec.worktree,
                                                     plotFolder: spec.inPlotFolder))
    }

    /// "Session ended", New session: `loam start` with a new session ID, in the same place and repo.
    public func newSession(in pane: PaneID) {
        guard let spec = workspace.spec(of: pane), spec.kind == .session,
              workspace.session(of: pane)?.exited == true else { return }
        workspace.restartPane(pane, with: newSessionSpec(in: spec.plot, repo: spec.repo, worktree: spec.worktree,
                                                         plotFolder: spec.inPlotFolder))
    }

    /// The pane that runs or ran a session, for the actor label in the review.
    public func paneRef(forSession id: String) -> PaneRef? {
        guard let pane = workspace.pane(forSession: id), let spec = workspace.spec(of: pane) else { return nil }
        let plotName = plots.first { $0.id == spec.plot }?.name ?? archivedPlots.first { $0.id == spec.plot }?.name
        return PaneRef(id: pane, name: plotName.map { "\(spec.title) \u{00B7} \($0)" } ?? spec.title)
    }

    /// Makes the pane's plot active and focuses the pane. The switcher counts it as a use.
    public func goToPane(_ pane: PaneID) {
        guard let plot = workspace.spec(of: pane)?.plot else { return }
        if plot != workspace.activePlotID { activate(plot: plot) }
        focus(pane)
    }

    /// Ghostty `equalize_splits`, on the selected tab of the active plot.
    public func equalizeSplits() {
        guard let plot = workspace.activePlotID else { return }
        workspace.equalize(plot: plot)
    }

    /// Ghostty `resize_split`, on the focused pane. `delta` is a fraction of the split (0.05 is 5 percent).
    public func resizeSplit(_ direction: SplitTree.ResizeDirection, by delta: Double) {
        guard let plot = workspace.activePlotID, let tab = workspace.selectedTab(of: plot) else { return }
        workspace.resize(plot: plot, pane: tab.focused, toward: direction, by: delta)
    }

    /// A divider drag: sets the ratio of the split at `path` in the selected tab.
    public func setSplitRatio(_ ratio: Double, at path: [Int]) {
        guard let plot = workspace.activePlotID else { return }
        workspace.setRatio(ratio, at: path, plot: plot)
    }

    public func selectTab(number: Int) {
        guard let plot = workspace.activePlotID else { return }
        workspace.selectTab(number: number, in: plot)
    }

    /// A click on a tab of the tab bar: selects by position, so tab 9 of 12 is the 9th tab.
    public func selectTab(index: Int) {
        guard let plot = workspace.activePlotID else { return }
        workspace.selectTab(index: index, in: plot)
    }

    /// A drag in the tab bar (ticket 98): moves the tab at `from` to `to` in the active plot. The
    /// selected tab stays selected, and ⌘1 to ⌘9 follow the new order.
    public func moveTab(from: Int, to: Int) {
        guard let plot = workspace.activePlotID else { return }
        workspace.moveTab(from: from, to: to, in: plot)
    }

    public func nextTab() { if let plot = workspace.activePlotID { workspace.nextTab(in: plot) } }
    public func previousTab() { if let plot = workspace.activePlotID { workspace.previousTab(in: plot) } }

    public func focus(_ pane: PaneID) {
        let changed = workspace.selectedTab(of: workspace.spec(of: pane)?.plot ?? "")?.focused != pane
        workspace.focus(pane)
        if changed { useTimes?.record(SwitcherItem.paneKey(pane.uuidString)) }
    }

    /// The terminal reports a new title for the pane.
    public func setTerminalTitle(_ title: String, of pane: PaneID) {
        guard terminalTitles[pane] != title else { return }
        terminalTitles[pane] = title
        guard !titleChangePending else { return }
        titleChangePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.titleChangePending = false
                self?.onTitleChange?()
            }
        }
    }

    /// `loam open` for a link, with the rule of the plot panel. A failure sets `lastError`.
    public func openLink(plot: String, link: String) async {
        do { _ = try await client.open(plot: plot, link: link) } catch { report(error) }
    }

    /// Ghostty `goto_split`, in the selected tab of the active plot.
    public func focusPane(_ step: AppCommand.PaneStep) {
        guard let plot = workspace.activePlotID else { return }
        switch step {
        case .next: workspace.focusNextPane(in: plot)
        case .previous: workspace.focusPreviousPane(in: plot)
        case .left: workspace.focusPane(toward: .left, in: plot)
        case .right: workspace.focusPane(toward: .right, in: plot)
        case .up: workspace.focusPane(toward: .up, in: plot)
        case .down: workspace.focusPane(toward: .down, in: plot)
        }
    }

    /// Ghostty `close_tab`: closes the selected tab of the active plot at once. The window asks
    /// first when a session in the tab is mid-turn (`ClosePrompt`). Returns false when there is no tab.
    @discardableResult
    public func closeTab() -> Bool {
        guard let plot = workspace.activePlotID, workspace.selectedTab(of: plot) != nil else { return false }
        workspace.closeSelectedTab(in: plot)
        return true
    }

    /// The close button of a tab (ticket 96): closes that tab of the active plot at once, selected
    /// or not, and leaves the selection on the same tab. Returns false when the plot has no such tab.
    @discardableResult
    public func closeTab(_ id: UUID) -> Bool {
        guard let plot = workspace.activePlotID, workspace.tabs(of: plot).contains(where: { $0.id == id }) else { return false }
        workspace.closeTab(id, in: plot)
        return true
    }

    /// Closes the focused pane of the active plot. Returns false when there is none.
    @discardableResult
    public func closeFocusedPane() -> Bool {
        guard let plot = workspace.activePlotID, let pane = workspace.selectedTab(of: plot)?.focused else { return false }
        workspace.closePane(pane)
        return true
    }

    // MARK: Worktrees

    /// The checks of a worktree, from the last list.
    public func worktreeStatus(_ id: String) -> WorktreeStatus? {
        worktrees.values.joined().first { $0.worktree.id == id }
    }

    /// The line that the "Session ended" bar adds when the pane's worktree is gone. Nil otherwise.
    public func endedNote(of pane: PaneID) -> String? {
        guard let ref = workspace.spec(of: pane)?.worktree else { return nil }
        return WorktreeRules.endedNote(for: ref, status: worktreeStatus(ref.id))
    }

    /// The folders of the panes that are open, for the removal checks. A worktree pane counts by its
    /// worktree folder, a shell pane by its start folder.
    public var openPaneFolders: [String] {
        workspace.livePaneIDs.compactMap(workspace.folder(of:))
    }

    /// `loam worktree new`, then a seeded session in the new worktree. `repo` nil means the main repo.
    /// Returns the worktree, or nil with `lastError` set.
    @discardableResult
    public func newWorktree(in plot: String, named name: String, repo: String? = nil, base: String? = nil) async -> Worktree? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        do {
            let repoPath: String
            if let repo {
                repoPath = repo
            } else if let main = try await client.show(plot: plot).repos.first(where: \.main) {
                repoPath = main.path
            } else {
                lastError = "The plot has no repo. Add a repo first."
                return nil
            }
            let made = try await client.worktreeNew(plot: plot, repo: repoPath, name: name, base: base)
            lastError = nil
            await reloadWorktrees()
            openWorktreePane(made.worktree)
            return made.worktree
        } catch {
            report(error)
            return nil
        }
    }

    /// Opens a tab in the worktree with a seeded session. `loam start --worktree` runs the setup
    /// command first, and asks on the terminal when the command is new or changed.
    public func openWorktreePane(_ worktree: Worktree, kind: PaneSpec.Kind = .session) {
        if workspace.activePlotID != worktree.plotID { activate(plot: worktree.plotID) }
        openTab(kind, worktree: WorktreeRef(worktree))
    }

    /// Focuses a pane that runs in the worktree. Opens a new session when there is none.
    public func showWorktree(_ worktree: Worktree) {
        if let pane = workspace.allPaneIDs.first(where: { workspace.spec(of: $0)?.worktree?.id == worktree.id }) {
            goToPane(pane)
        } else {
            openWorktreePane(worktree)
        }
    }

    /// How many panes are open in the worktree, and how many saved panes have not resumed.
    public func paneCounts(in worktree: Worktree) -> (open: Int, saved: Int) {
        (WorktreeRules.count(in: worktree, folders: openPaneFolders),
         WorktreeRules.count(in: worktree, folders: savedPaneFolders()))
    }

    /// Reads the checks again, then decides what removal needs. Nil when the worktree is unknown.
    public func planRemoval(of id: String) async -> WorktreeRemovalPlan? {
        await reloadWorktrees()
        guard let status = worktreeStatus(id) else { return nil }
        let counts = paneCounts(in: status.worktree)
        return WorktreeRules.plan(for: status, openPanes: counts.open, savedPanes: counts.saved)
    }

    /// `loam worktree rm`. The core checks again with the open and saved pane folders, so a pane that
    /// opened after the plan still stops it. A refusal sets `lastError`. Returns true when removed.
    @discardableResult
    public func removeWorktree(_ id: String, force: Bool = false) async -> Bool {
        guard let status = worktreeStatus(id) else { return false }
        // The core reads the panes of state.json. Write a pending change first, so a pane that
        // closed less than a second ago does not count.
        await stateWriter?.flushed()
        do {
            _ = try await client.worktreeRemove(plot: status.worktree.plotID, worktree: id, force: force,
                                                openPanes: openPaneFolders + savedPaneFolders())
            lastError = nil
            await reloadWorktrees()
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: Plot lifecycle (spec section 10)

    /// The question before archive, or nil when no session in the plot asks.
    /// It uses the `ClosePrompt` rule, so ticket 32 adds "needs you" in one place.
    public func archivePrompt(for plot: String) -> ClosePrompt? {
        ClosePrompt.make(.archive, closing: workspace.livePaneIDs(of: plot), in: workspace)
    }

    /// `loam archive`, then the plot's panes end and the layout stays. The panes wait like restored
    /// panes: `loam resume` brings each session back when you unarchive the plot and show it.
    /// The app asks first (`archivePrompt`). A failed archive ends no session.
    @discardableResult
    public func archivePlot(_ id: String) async -> Bool {
        guard var row = plots.first(where: { $0.id == id }) else { return false }
        do {
            _ = try await client.archive(plot: id)
        } catch {
            report(error)
            return false
        }
        lastError = nil
        var next = workspace
        let wasActive = next.activePlotID == id
        next.suspendPlot(id) { pane, spec, session in
            switch spec.kind {
            case .session:
                (session.sessionID ?? spec.sessionID).map {
                    resumeSpec(in: id, sessionID: $0, repo: spec.repo, worktree: spec.worktree, plotFolder: spec.inPlotFolder)
                } ?? spec
            case .shell:
                newShellSpec(in: id, folder: workspace.folder(of: pane), worktree: spec.worktree)
            }
        }
        // The panes and the active plot change in one step, so the window never shows a waiting plot.
        // The index is read again here: a feed reload can change the list during the await.
        let index = plots.firstIndex(where: { $0.id == id }) ?? plots.count
        let rest = plots.filter { $0.id != id }
        if wasActive {
            if panel.visible { review.markSeen(plot: id) }
            let neighbour = rest.indices.contains(index) ? rest[index].id : rest.last?.id
            next.activate(plot: neighbour)
            if let neighbour { useTimes?.record(SwitcherItem.plotKey(neighbour)) }
        }
        workspace = next
        row.archived = true
        archivedPlots = [row] + archivedPlots.filter { $0.id != id }
        plots = rest
        await reloadPlots()
        return true
    }

    /// `loam unarchive`. The plot goes back to its old place. Its panes start when you first show it.
    @discardableResult
    public func unarchivePlot(_ id: String) async -> Bool {
        do {
            _ = try await client.unarchive(plot: id)
            lastError = nil
            await reloadPlots()
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// `loam delete` of an archived plot. The plot's panes leave the workspace, and the next layout
    /// write removes them from `state.json`. Returns the result (the Trash folder and the Claude Code
    /// folders that Loam left alone), or nil with `lastError` set.
    public func deletePlot(_ id: String) async -> DeleteResult? {
        guard archivedPlots.contains(where: { $0.id == id }) else {
            lastError = "Archive the plot first. Delete works only on an archived plot."
            return nil
        }
        do {
            let result = try await client.delete(plot: id)
            lastError = nil
            await reloadPlots()
            return result
        } catch {
            report(error)
            return nil
        }
    }

    /// Closes one pane, for example when its shell exits.
    public func closePane(_ pane: PaneID) { workspace.closePane(pane) }
}
