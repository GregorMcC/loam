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
    /// Settings > Connections: the Linear API key (ticket 205).
    public let connections: ConnectionsModel
    public let runsSettings: RunsSettingsModel
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
            // A move of the focus or of the active space ends the selection of a worktree row (ticket 107).
            if storedWorkspace.focusedPane != oldValue.focusedPane || storedWorkspace.activeSpace != oldValue.activeSpace {
                endWorktreeSelection()
            }
            if storedWorkspace.activeSpace != oldValue.activeSpace { recordPlace() }
            if let pane = storedWorkspace.focusedPane, pane != oldValue.focusedPane {
                focusCount += 1
                lastFocus[pane] = focusCount
            }
            attentionChanged()
            closedShipPanes()
            onWorkspaceChange?()
            saveLayout()
        }
    }
    /// The worktree row that ⌘⇧L selected, for a worktree that has no pane to focus (ticket 107). It stays
    /// until the focus or the active space moves, or until an explicit focus of a pane or activation of a
    /// plot, even when that pane or plot is the one you are in (`endWorktreeSelection`).
    public private(set) var selectedWorktree: String?

    /// Ends the selection of a worktree row. A click on the focused pane or on the active plot moves
    /// nothing in the workspace, so the workspace cannot tell that the selection is over.
    private func endWorktreeSelection() {
        if selectedWorktree != nil { selectedWorktree = nil }
    }
    /// The worktrees of each plot with their checks, as the core last listed them.
    public private(set) var worktrees: [String: [WorktreeStatus]] = [:] {
        didSet {
            guard worktrees != oldValue else { return }
            followPullRequestRow()
            followLandSheet()
            followMergeAsks()
            onWorkspaceChange?()
        }
    }
    /// The PR popover (ticket 109).
    @ObservationIgnored public let prPopover = PRPopoverModel()
    /// The Land sheet (ticket 112).
    @ObservationIgnored public let landSheet = LandSheetModel()
    /// The merges on GitHub that ask with a callout at the top of the plot panel (ticket 113), oldest first.
    public internal(set) var mergeAsks: [MergedPR] = []
    /// The merges that this run of the app decided on, so that each merge acts once.
    @ObservationIgnored var mergesDecided: Set<MergedPR> = []
    /// The merges that you kept. `startRestore` reads them from `state.json`.
    @ObservationIgnored public internal(set) var keptMerges = KeptMerges()
    /// The worktrees whose removal after a merge runs now.
    @ObservationIgnored var mergeRemovals: Set<String> = []
    /// The actions after merges that run now, one after the other.
    @ObservationIgnored var mergeActions: Task<Void, Never>?
    /// True when a shell pane runs a process, such as a dev server, so that Loam does not close it with no question
    /// after a merge (ticket 113). The window reads the terminal. The default says yes, so with no terminal to read,
    /// Loam asks.
    @ObservationIgnored public var paneRunsAProcess: (PaneID) -> Bool = { _ in true }
    /// The New worktree sheet (ticket 115).
    @ObservationIgnored public let newWorktreeSheet = NewWorktreeModel()
    /// Asks the question of a close that ends a session in a turn, and returns true on the confirm button. The window
    /// shows it as a sheet. The default says no, so a land with no window never stops a session.
    @ObservationIgnored public var confirmClose: (ClosePrompt) async -> Bool = { _ in false }
    /// Returns when the views of the closed panes are gone, and so are their processes. The window sets it. A land
    /// removes the folder of the panes, so it waits for them.
    @ObservationIgnored public var paneClosesFinished: () async -> Void = {}
    /// Tells the action bar about a change that the app made itself, so the toast of the app is not replaced by
    /// "You set Where it stands".
    @ObservationIgnored public var onOwnChange: ((Int) -> Void)?
    /// Copies text to the clipboard (ticket 110). The window sets the clipboard of the Mac, and the driver a
    /// private one.
    @ObservationIgnored public var copyText: (String) -> Void = { _ in }
    /// Shows a line in the toast of the action bar (ticket 110). The window sets it.
    @ObservationIgnored public var onToast: ((String, ActionBarModel.ToastKind) -> Void)?
    /// Send to session typed a prompt into the pane and focused it. The window gives the keys to its terminal.
    @ObservationIgnored public var onPromptTyped: ((PaneID) -> Void)?
    /// How long Start session with prompt waits for the `SessionStart` of the new session (ticket 110). The toast
    /// after it says 30 seconds. Tests make the wait short.
    @ObservationIgnored public var sessionStartWait: Duration = .seconds(30)
    /// When each pane last had the focus, as a count that goes up. Send to session types into the session of
    /// the worktree that you focused last.
    @ObservationIgnored private var lastFocus: [PaneID: Int] = [:]
    @ObservationIgnored private var focusCount = 0
    /// The sessions that Start session with prompt opened, until their first `SessionStart`: the worktree whose
    /// prompt each gets, and the wait that ends at `sessionStartWait`.
    @ObservationIgnored private var startPrompts: [PaneID: (worktree: String, wait: Task<Void, Never>)] = [:]
    /// The refresh of one worktree that runs now, for each worktree (`refreshWorktree`).
    @ObservationIgnored private var worktreeRefreshes: [String: Task<Bool, Never>] = [:]
    /// Panes that were saved and have not resumed, as folders. Removal refuses while one lies in the
    /// worktree. The default reads the restored panes that wait for their plot to show (ticket 29).
    @ObservationIgnored private var worktreeReads = 0
    /// The plain worktree reads that run now, and how many applied (`refreshWorktrees` reads both).
    @ObservationIgnored private var worktreeReadsRunning = 0
    @ObservationIgnored private var worktreeReadsApplied = 0
    /// When the ship state of the worktrees refreshes (ticket 108). It stays idle until `launch` starts it.
    @ObservationIgnored public let shipRefresh: ShipRefresher
    /// The notices that you dismissed. They stay hidden until the app quits.
    public private(set) var dismissedShipNotices: Set<ShipNotice> = []
    /// The plots that refresh because `gh` works again for another plot (`recheckGitHubNotes`).
    @ObservationIgnored private var rechecking: Set<String> = []
    /// The panes that Sign in opened, with their plots. The plot refreshes when one closes.
    @ObservationIgnored private var signInPanes: [PaneID: String] = [:]
    /// Types text into the terminal of a pane as a paste, with no Return. False while the pane has no
    /// terminal. The terminal factory sets it. `type(_:into:)` keeps the text until it returns true. A
    /// terminal that refuses the text throws, and `deliverUnsentText` drops the text and reports why.
    @ObservationIgnored public var typeIntoPane: (PaneID, String) throws -> Bool = { _, _ in false }
    @ObservationIgnored private var unsentText: [PaneID: [String]] = [:]
    /// The shells that text waits for (`typeAtPrompt`). Each holds the wait that ends at `shellWait`.
    @ObservationIgnored private var shellWaits: [PaneID: Task<Void, Never>] = [:]
    /// The longest time that text waits for a shell to show its first prompt.
    @ObservationIgnored public var shellWait: Duration = .seconds(3)
    /// The plot list read that runs now, and the calls asked and served (`reloadPlots`).
    @ObservationIgnored private var plotRead: Task<Void, Never>?
    @ObservationIgnored private var plotReadsWanted = 0
    @ObservationIgnored private var plotReadsDone = 0
    @ObservationIgnored public var savedPaneFolders: () -> [String] = { [] }
    public var sidebarCollapsed = false { didSet { onWorkspaceChange?(); saveLayout() } }
    /// The last core error, in words for a person. The window shows it.
    public var lastError: String?
    /// The runs of every plot, newest first, as the core last listed them (ticket 203).
    public internal(set) var runs: [Run] = [] { didSet { if runs != oldValue { onWorkspaceChange?() } } }
    /// What the desk shows (ticket 207).
    public internal(set) var desk = DeskState()
    /// The time between the ticks that ship runs (ticket 206).
    public var runTickInterval: Duration = .seconds(30)
    /// The loop of `startRunTicks`, or nil before it starts.
    var runTicks: Task<Void, Never>?
    /// The page that the well shows in place of the tabs and panes: Today or a run. Nil shows the panes.
    /// A move to a space or a pane closes it.
    public internal(set) var page: AppPage? {
        didSet {
            guard page != oldValue else { return }
            // The desk and a run page open from Today, so you leave Today only when you leave all three.
            if Self.isTodayGroup(oldValue), !Self.isTodayGroup(page) { leftToday() }
            recordPlace()
            onWorkspaceChange?()
        }
    }
    /// The places that Back and Forward go to (TAS-46), in memory only.
    public internal(set) var history = PageHistory()
    /// True while a move that changes the page and the space at once runs, so the history records one step.
    var holdsPlace = false
    /// What Today reads besides the runs.
    public internal(set) var todayData = TodayData()
    /// The run that the run page shows, with its history, as the core last read it.
    public internal(set) var runStatus: RunStatus?
    /// A shape that the start form started and that has not ended. The desk opens on its run when the run shows
    /// up, so you see Claude draft it.
    var pendingShape: PendingShape?
    /// The run defaults of the plot of the start form or the Recurring page, as the core last read them.
    public internal(set) var runDefaults: RunDefaults?
    /// The MCP servers that `--mcp` can select, as the core last read them. Nil when the last read failed.
    public internal(set) var mcpServers: [MCPServer]?
    /// The run defaults to save next, by plot, while a save runs. A later request replaces an earlier one of the same
    /// plot that waits.
    var pendingRunDefaults: [String: RunDefaultsRequest] = [:]
    /// True while a save of run defaults runs, so the saves go one after the other.
    var isSavingRunDefaults = false
    /// Why the run defaults could not be saved, for the Recurring page.
    public internal(set) var runDefaultsError: String?
    /// The intake that the Intake page shows, as the core last read it (ticket 204).
    public internal(set) var intake: IntakeList?
    /// Why the last run did not start, for the Intake page.
    public internal(set) var runStartError: String?
    /// True while `loam run start` runs.
    public internal(set) var isStartingRun = false
    /// The bases of the main repo of the plot of the start form (TAS-21), or nil before they are read.
    public internal(set) var runBases: RunBases?
    /// The recurring runs of the plot that the Recurring page shows (ticket 208).
    public internal(set) var recurring: [Recurring] = []
    /// Why the last change of a recurring run failed, for the Recurring page.
    public internal(set) var recurringError: String?
    /// Whether launchd runs `loam tick` while the app is closed, as the core last said. Nil before the first read.
    public internal(set) var tickStatus: TickStatus?
    /// True when a plot has a recurring run, as the last list said.
    var hasRecurring = false
    /// The rules of the plot that the Recurring page shows (ticket 209).
    public internal(set) var rules: [Rule] = []
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
    /// The active space of the saved layout. The window reads it once when it opens.
    public var restoredSpace: Space? { pendingRestore?.layout.active }
    /// The window frame. The window sets it after a move or a resize.
    @ObservationIgnored public var windowFrame: CGRect? { didSet { if windowFrame != oldValue { saveLayout() } } }

    public init(client: LoamClient = LoamClient(), stateFile: AppStateFile = AppStateFile(),
                settingsFile: SettingsFile? = nil, shipRefresh: ShipRefresher = ShipRefresher()) {
        self.client = client
        self.shipRefresh = shipRefresh
        // The file is in the client's LOAM_HOME, so a test store has its own settings.
        self.settings = SettingsModel(file: settingsFile ?? SettingsFile(environment: client.environment),
                                      launchBinary: client.binary.path)
        self.connections = ConnectionsModel(client: client)
        self.runsSettings = RunsSettingsModel(client: client)
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
        shipRefresh.run = { [weak self] in await self?.refreshWorktrees(plot: $0) }
        shipRefresh.isRefreshable = { [weak self] id in self?.plots.contains { $0.id == id } ?? false }
        shipRefresh.activePlot = { [weak self] in self?.workspace.activePlotID }
        shipRefresh.otherPlots = { [weak self] in
            guard let self else { return [] }
            return plots.map(\.id).filter { $0 != workspace.activePlotID }
        }
        shipRefresh.isFrontmost = { [weak self] in self?.isFrontmost() ?? false }
    }

    public var sidebar: SidebarModel {
        SidebarModel(
            plots: plots, workspace: workspace, collapsed: sidebarCollapsed,
            newChangeCounts: review.sidebarCounts(activePlot: workspace.activePlotID), worktrees: worktrees,
            arriving: arrivingPanes(), repos: repoCheckouts, titles: terminalTitles, selectedWorktree: selectedWorktree,
            page: page, runWorktrees: Set(runs.filter { !$0.state.ended && !$0.worktreeID.isEmpty }.map(\.worktreeID)))
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
        keptMerges = KeptMerges(writer: writer)
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
            resumeSpec(in: pane.space, sessionID: $0, repo: pane.repo, worktree: pane.worktree,
                       plotFolder: pane.plotFolder ?? false)
        }
        case .shell: newShellSpec(in: pane.space, folder: pane.folder, worktree: pane.worktree)
        }
    }

    /// At quit, before the panes close: the last layout write, then no more writes, so the closes
    /// keep every pane in `state.json`. The changes in an open panel count as seen (ticket 36),
    /// and the panel stays open in the saved layout.
    public func prepareForQuit() {
        shipRefresh.stop()
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
            await reloadRuns()
            if shouldStartFeed {
                startFeed()
                shipRefresh.start()
                startRunTicks()
            }
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

    /// Reads the worktrees of every plot, with the ship state that the core cached. A failed read keeps
    /// the last list.
    public func reloadWorktrees() async {
        worktreeReads += 1
        let mine = worktreeReads
        worktreeReadsRunning += 1
        defer { worktreeReadsRunning -= 1 }
        guard let all = try? await client.worktrees(), mine == worktreeReads else { return }  // A newer read wins.
        worktrees = Dictionary(grouping: all, by: { $0.worktree.plotID })
        worktreeReadsApplied += 1
        keptMerges.prune(keeping: Set(all.map(\.worktree.id)))
    }

    /// Asks GitHub for the ship state of the worktrees of one plot (`loam worktree list <plot>
    /// --refresh`) and shows the answer (ticket 108). The refresh writes no change, so the feed does
    /// not tell the app: the answer is how the app learns. A failed refresh keeps the last rows, and
    /// their age shows in the section. A read of the cache that ran meanwhile can know a worktree that
    /// the answer lacks, or hold older state, so the app reads again after it.
    public func refreshWorktrees(plot: String) async {
        let applied = worktreeReadsApplied
        guard let rows = try? await client.worktrees(plot: plot, refresh: true) else { return }
        await show(refreshed: rows, plot: plot, askedAbout: rows, readsApplied: applied)
    }

    /// Shows the answer of a refresh. `askedAbout` are the rows that the refresh asked GitHub about: they
    /// tell whether `gh` works. `applied` is `worktreeReadsApplied` from before the refresh started.
    private func show(refreshed rows: [WorktreeStatus], plot: String, askedAbout: [WorktreeStatus], readsApplied applied: Int) async {
        worktreeReads += 1  // A read of the cache that started before the answer must not replace it.
        worktrees[plot] = rows.isEmpty ? nil : rows
        if worktreeReadsRunning > 0 || worktreeReadsApplied != applied { await reloadWorktrees() }
        if !askedAbout.contains(where: \.holdsGitHubNote), askedAbout.contains(where: \.githubAnswered) {
            recheckGitHubNotes(except: plot)
        }
        followMerges(of: askedAbout.map(\.worktree.id))
    }

    /// Asks GitHub about one worktree (`loam worktree list <plot> --refresh --worktree <id>`) and shows the
    /// answer (ticket 109). The other rows of its plot stay as the core cached them. An ask while the refresh
    /// of the worktree runs joins it, so a burst of opens of the PR popover runs one `loam`. `afterChange`
    /// is for a button that changed the PR, and for Refresh in the ⌘J menu, where a push may have come a
    /// moment ago: a refresh that started before the change cannot show it, so the ask waits for that one and
    /// then asks again. Returns false when the worktree is unknown or the core gave no answer. The rows stay
    /// then.
    @discardableResult
    public func refreshWorktree(_ id: String, afterChange: Bool = false) async -> Bool {
        if afterChange, let running = worktreeRefreshes[id] { _ = await running.value }
        return await worktreeRefresh(id)?.value ?? false
    }

    /// The refresh of the worktree that runs now, else a new one. Nil when the worktree is unknown.
    @discardableResult
    private func worktreeRefresh(_ id: String) -> Task<Bool, Never>? {
        if let running = worktreeRefreshes[id] { return running }
        guard let plot = worktreeStatus(id)?.worktree.plotID else { return nil }
        let applied = worktreeReadsApplied
        prPopover.beginRefresh(of: id)
        let refresh = Task { [weak self] () -> Bool in
            guard let self else { return false }
            let rows = try? await client.refreshWorktree(plot: plot, worktree: id)
            if let rows {
                await show(refreshed: rows, plot: plot, askedAbout: rows.filter { $0.worktree.id == id }, readsApplied: applied)
            }
            worktreeRefreshes[id] = nil
            prPopover.endRefresh(of: id, answered: rows != nil)
            return rows != nil
        }
        worktreeRefreshes[id] = refresh
        return refresh
    }

    /// `gh` answered for a plot, so it works again. The Ready to merge row stays hidden while any plot
    /// holds the note of a missing or signed out `gh` (`SidebarModel.showsReadyToMerge`), and "check
    /// again" asks for one plot only. So each other plot that holds the note refreshes too. It goes
    /// through the refresher, so it joins a refresh of that plot that runs now. The plots refresh one
    /// after the other, so a fix does not start a `loam` process for every plot at once. A plot that
    /// waits for this reason, or refreshes for it, does not start the same refresh again, so the answers
    /// of these refreshes do not start each other.
    private func recheckGitHubNotes(except plot: String) {
        func holdsNote(_ id: String) -> Bool { worktrees[id]?.contains(where: \.holdsGitHubNote) == true }
        let holding = plots.map(\.id).filter { $0 != plot && !rechecking.contains($0) && holdsNote($0) }
        guard !holding.isEmpty else { return }
        rechecking.formUnion(holding)
        Task {
            for id in holding {
                // A plot that cleared its note meanwhile needs none. A plot whose refresh runs now is left to
                // that refresh, since one more would repeat it.
                if holdsNote(id), !shipRefresh.isRefreshing(id) { await shipRefresh.refresh(id) }
                rechecking.remove(id)
            }
        }
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

    func report(_ error: Error) {
        lastError = Self.message(for: error)
    }

    static func message(for error: Error) -> String {
        (error as? LoamError)?.userMessage ?? String(describing: error)
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
        let activeShown = switch next.activeSpace {
        case .home: true
        case .plot(let id): ids.contains(id)
        case nil: false
        }
        // With no plot, Home shows, so ⌘T and ⌘⌥T work on a fresh install (ticket 99).
        if !activeShown { next.activate(list.first.map { .plot($0.id) } ?? .home) }
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
                await self.reloadRuns()
            }
        }
    }

    public func stopFeed() { feedTask?.cancel() }

    /// `loam new --json`, then the new plot becomes active. Returns its ID, or nil when no plot was made.
    @discardableResult
    public func newPlot(named name: String) async -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        do {
            let plot = try await client.new(name: name)
            await reloadPlots()
            activate(plot: plot.id)
            return plot.id
        } catch {
            report(error)
            return nil
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

    // MARK: Space selection

    public func activate(plot id: String) {
        guard plots.contains(where: { $0.id == id }) else { return }
        activate(.plot(id))
    }

    /// ⌃0: makes Home active (ticket 99).
    public func activateHome() { activate(.home) }

    private func activate(_ space: Space) {
        endWorktreeSelection()
        let opens = space != workspace.activeSpace
        asOneStep {
            page = nil
            // A switch with the panel open marks the plot that you leave as seen.
            if panel.visible, opens { review.markSeen(plot: workspace.activePlotID) }
            workspace.activate(space)
        }
        useTimes?.record(SwitcherItem.key(of: space))
        if panel.visible { Task { await reloadPanel() } }
        if opens, let plot = space.plotID { Task { await shipRefresh.refresh(plot) } }
    }

    /// Makes the space active, unless it is a plot that is not in the list.
    public func show(_ space: Space) {
        switch space {
        case .home: activateHome()
        case .plot(let id): activate(plot: id)
        }
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

    /// The home folder that the panes see. Home panes start there (ticket 99). libghostty starts each
    /// pane through `login`, which sets `HOME` from the user record, so the app's `HOME` does not
    /// count. `NSHomeDirectory()` reads the user record too. Tests set it.
    @ObservationIgnored public var homeFolder = NSHomeDirectory()

    /// Where a shell pane of the space starts (spec 8.2): the main repo, or the plot folder when the
    /// plot has no repos. A failed read gives the plot folder. A Home shell starts in the home folder.
    public func startFolder(of space: Space) async -> String {
        guard case .plot(let plot) = space else { return homeFolder }
        let main = try? await client.show(plot: plot).repos.first(where: \.main)?.path
        return main ?? plotFolder(plot)
    }

    /// A new session: `loam start` with a new session ID. The pane gets the client's environment,
    /// so it talks to the same store as the app.
    /// With `worktree`, the command is `loam start <plot> --worktree <id> ...`. In Home, it is
    /// `loam start --home`, and `repo`, `worktree`, and `plotFolder` must be left out.
    public func newSessionSpec(in space: Space, repo: String? = nil, worktree: WorktreeRef? = nil,
                               plotFolder: Bool = false) -> PaneSpec {
        let id = UUID().uuidString.lowercased()
        let command = switch space {
        case .home:
            PaneCommand.startHome(shell: shell, loam: client.binary.path, sessionID: id)
        case .plot(let plot):
            PaneCommand.start(shell: shell, loam: client.binary.path, plot: plot, repo: repo,
                              worktree: worktree?.id, plotFolder: plotFolder, sessionID: id)
        }
        return sessionSpec(in: space, command: command, sessionID: id, repo: repo, worktree: worktree, plotFolder: plotFolder)
    }

    /// Opens a plot session (ticket 93): a seeded session in the plot folder, with every repo as an
    /// added folder. It makes the plot active first.
    public func openPlotSession(_ plot: String) {
        if workspace.activePlotID != plot { activate(plot: plot) }
        guard workspace.activePlotID == plot else { return }
        workspace.openTab(newSessionSpec(in: .plot(plot), plotFolder: true))
    }

    /// Resumes a session in the space: `loam resume` in a plot, `loam start --home --resume` in
    /// Home. In a plot, the core resumes in the worktree, or fails if it is gone. `plotFolder` marks
    /// a plot session (ticket 93). `loam resume` finds the folder from the record.
    public func resumeSpec(in space: Space, sessionID: String, repo: String? = nil, worktree: WorktreeRef? = nil,
                           plotFolder: Bool = false) -> PaneSpec {
        let command = switch space {
        case .home: PaneCommand.resumeHome(shell: shell, loam: client.binary.path, sessionID: sessionID)
        case .plot: PaneCommand.resume(shell: shell, loam: client.binary.path, sessionID: sessionID)
        }
        return sessionSpec(in: space, command: command, sessionID: sessionID, repo: repo, worktree: worktree,
                           plotFolder: plotFolder)
    }

    private func sessionSpec(in space: Space, command: String, sessionID: String, repo: String?,
                             worktree: WorktreeRef?, plotFolder: Bool) -> PaneSpec {
        assert(!space.isHome || (repo == nil && worktree == nil && !plotFolder), "a Home session has no repo, worktree, or plot folder")
        var spec = PaneSpec(kind: .session, space: space, command: command, env: client.environment,
                            title: "claude", repo: repo, sessionID: sessionID, worktree: worktree)
        spec.inPlotFolder = plotFolder
        return spec
    }

    /// A login shell. `folder` nil starts it in your home folder. A worktree sets the folder.
    public func newShellSpec(in space: Space, folder: String? = nil, worktree: WorktreeRef? = nil) -> PaneSpec {
        PaneSpec(kind: .shell, space: space, folder: worktree?.path ?? folder, env: client.environment, title: "shell",
                 worktree: worktree)
    }

    private func spec(_ kind: PaneSpec.Kind, in space: Space, folder: String?, repo: String? = nil,
                      worktree: WorktreeRef? = nil) -> PaneSpec {
        kind == .session ? newSessionSpec(in: space, repo: repo, worktree: worktree)
                         : newShellSpec(in: space, folder: folder, worktree: worktree)
    }

    // MARK: Tabs and splits of the active space

    /// Opens a tab in the active space. ⌘T opens a session. `repo` picks a repo other than the
    /// main repo for a session, and `folder` the start folder of a shell.
    public func openTab(_ kind: PaneSpec.Kind = .shell, folder: String? = nil, repo: String? = nil,
                        worktree: WorktreeRef? = nil) {
        guard let space = workspace.activeSpace else { return }
        page = nil
        workspace.openTab(spec(kind, in: space, folder: folder, repo: repo, worktree: worktree))
    }

    /// Opens a tab with a spec that the caller built, such as the attach tab of a run (ticket 203).
    func openTab(_ spec: PaneSpec) {
        page = nil
        workspace.openTab(spec)
    }

    /// ⌘D and ⌘⇧D split with a session. A shell split comes from the menu or ⌘J.
    public func split(_ axis: SplitAxis, _ kind: PaneSpec.Kind = .shell, folder: String? = nil) {
        guard let space = workspace.activeSpace else { return }
        workspace.split(in: space, axis: axis, spec(kind, in: space, folder: folder))
    }

    /// ⌘⌥T: a shell tab in the start folder of the space that is active at the call.
    public func openShellTab() async {
        guard let space = workspace.activeSpace else { return }
        let folder = await startFolder(of: space)
        guard workspace.activeSpace == space else { return }
        openTab(.shell, folder: folder)
    }

    /// A shell split in the start folder of the active space.
    public func splitShell(_ axis: SplitAxis) async {
        guard let space = workspace.activeSpace else { return }
        let folder = await startFolder(of: space)
        guard workspace.activeSpace == space else { return }
        split(axis, .shell, folder: folder)
    }

    /// ⌘J "New Session in Home" and "New Shell in Home" (ticket 99): makes Home active from any
    /// space, then opens the tab there.
    public func openHomeTab(_ kind: PaneSpec.Kind) {
        activateHome()
        openTab(kind, folder: kind == .shell ? homeFolder : nil)
    }

    // MARK: Move to Plot (ticket 100)

    /// The plots that a Home tab can move to, in sidebar order: the plots with panes, then the rest.
    public var moveTargets: [PlotSummary] {
        let withPanes = Set(workspace.plotIDsWithPanes)
        return plots.filter { withPanes.contains($0.id) } + plots.filter { !withPanes.contains($0.id) }
    }

    /// The question before a move, or nil when no session in the tab asks. A move stops each session,
    /// so it uses the `ClosePrompt` rule.
    public func movePrompt(tab id: UUID) -> ClosePrompt? {
        guard let tab = workspace.tabs(of: .home).first(where: { $0.id == id }) else { return nil }
        return ClosePrompt.make(.move, closing: tab.tree.paneIDs, in: workspace)
    }

    /// Moves a Home tab with all its panes to a plot of the list. The plot becomes active with the tab
    /// selected. A shell keeps its process and the environment it started with, so it has no
    /// `LOAM_PLOT`. A session stops and resumes in the plot with `loam resume <id> --plot <plot>`, in
    /// the home folder, where Claude Code keeps a Home session. It resumes the ID that the pane has
    /// now, because `/clear` changes it. The window asks first (`movePrompt`). Returns false when
    /// the tab is not in Home or the plot is not in the list.
    @discardableResult
    public func moveToPlot(tab id: UUID, plot: String) -> Bool {
        guard plots.contains(where: { $0.id == plot }),
              let tab = workspace.tabs(of: .home).first(where: { $0.id == id }) else { return false }
        let space = Space.plot(plot)
        // A switch first, so the panel and the switcher see it as any switch. The move and the
        // restarts then change the workspace in one step.
        activate(space)
        var next = workspace
        next.moveTab(id, to: space)
        for pane in tab.tree.paneIDs {
            guard let spec = next.spec(of: pane), spec.kind == .session,
                  let sessionID = next.session(of: pane)?.sessionID ?? spec.sessionID else { continue }
            let command = PaneCommand.resumeInPlot(shell: shell, loam: client.binary.path, sessionID: sessionID, plot: plot)
            // The sidebar shows the session right under the plot, as a plot session.
            var moved = sessionSpec(in: space, command: command, sessionID: sessionID, repo: nil, worktree: nil, plotFolder: true)
            moved.folder = homeFolder
            next.restartPane(pane, with: moved)
        }
        workspace = next
        return true
    }

    /// "Move to New Plot…": `loam new`, then the move. A failed `loam new` moves nothing and sets
    /// `lastError`. A tab that left Home before the call makes no plot.
    public func moveToNewPlot(tab id: UUID, named name: String) async {
        guard workspace.tabs(of: .home).contains(where: { $0.id == id }),
              let plot = await newPlot(named: name) else { return }
        moveToPlot(tab: id, plot: plot)
    }

    // MARK: Sessions in panes

    /// The clock of the composer rule (ticket 110). Tests set it.
    @ObservationIgnored public var now: () -> Date = { Date() }

    /// A line from the pane's socket.
    public func apply(_ event: PaneEvent, to pane: PaneID) {
        let accepted = workspace.apply(event, to: pane, now: now())
        // A session that ends a turn in a plot may have pushed, or changed a PR (ticket 108).
        if accepted, event.event == "Stop", let plot = workspace.spec(of: pane)?.space.plotID {
            shipRefresh.stopped(in: plot)
        }
        // A session that Start session with prompt opened gets its prompt now (ticket 110).
        if event.event == "SessionStart" { typeStartPrompt(into: pane) }
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

    /// You put something into the pane: a key, a paste, a drop, or text from dictation. An arrow key can recall a
    /// prompt and Tab can complete one, so they count too. Send to session does not type into the pane until
    /// Claude Code takes the composer (the composer rule of `PaneSession`). A key changes the workspace only when
    /// it is the first input after a Return or a submit, and each submit Return changes it once.
    public func input(_ input: PaneInput, in pane: PaneID) {
        guard var session = workspace.session(of: pane) else { return }
        let before = session
        let time = now()
        session.input(input, now: time)
        guard session != before else { return }
        workspace.input(input, in: pane, now: time)
    }

    /// Loam became frontmost or stopped being frontmost. Done, unread of the pane that you see clears.
    public func frontmostChanged() {
        guard isFrontmost(), let pane = workspace.focusedPane, workspace.session(of: pane)?.doneUnread == true else { return }
        workspace.markSeen(pane)
    }

    /// Every pane of Home and of the plots in the sidebar, in sidebar order: Home, then plot order,
    /// then tab order, then layout order. The panes of archived plots are not in it.
    private var sidebarPaneIDs: [PaneID] {
        workspace.paneIDs(of: .home) + plots.flatMap { workspace.paneIDs(of: .plot($0.id)) }
    }

    /// The panes that need you, in sidebar order.
    public var needsYouPanes: [PaneID] {
        sidebarPaneIDs.filter { workspace.state(of: $0) == .needsYou }
    }

    /// The panes that need you in spaces other than the active one. The title bar button counts them.
    public var elsewhereNeedYouCount: Int {
        needsYouPanes.filter { workspace.spec(of: $0)?.space != workspace.activeSpace }.count
    }

    /// ⌘L: the next pane that needs you after the focused pane, in sidebar order, round to the start.
    /// `elsewhere` skips the panes of the active space (the title bar button). Nil when there is none.
    public func nextPaneThatNeedsYou(elsewhere: Bool = false) -> PaneID? {
        let waiting = Set(needsYouPanes.filter { !elsewhere || workspace.spec(of: $0)?.space != workspace.activeSpace })
        return AttentionCycle.next(order: sidebarPaneIDs, matching: waiting, after: workspace.focusedPane)
    }

    /// A place that a fixed attention row of the sidebar goes to: a pane, or a run that waits for you (TAS-45).
    public enum AttentionTarget: Hashable, Sendable {
        case pane(PaneID)
        case run(String)
    }

    /// The next pane or run in the state, after the one that you look at. The order is the panes in sidebar order,
    /// then the runs of Today, the longest wait first, round to the start. Nil when nothing is in the state.
    public func nextAttentionTarget(in attention: PaneAttention) -> AttentionTarget? {
        let today = today
        let (panes, runs): ([PaneID], [Run]) = switch attention {
        case .needsYou: (needsYouPanes, today.needsYou)
        case .doneUnread: (sidebarPaneIDs.filter { workspace.attention(of: $0) == .doneUnread }, today.doneUnread)
        case .none: ([], [])
        }
        let order = sidebarPaneIDs.map(AttentionTarget.pane) + runs.map { AttentionTarget.run($0.id) }
        let matching = Set(panes.map(AttentionTarget.pane) + runs.map { AttentionTarget.run($0.id) })
        let current: AttentionTarget? = switch page {
        case .desk: desk.runID.map(AttentionTarget.run)
        case .run(let id): .run(id)
        default: workspace.focusedPane.map(AttentionTarget.pane)
        }
        return AttentionCycle.next(order: order, matching: matching, after: current)
    }

    /// A click on a fixed attention row of the sidebar: goes to the next pane or run in that state, across spaces.
    /// It does nothing for another state or when nothing is in the state.
    public func goToNext(in attention: PaneAttention) async {
        switch nextAttentionTarget(in: attention) {
        case .pane(let pane): goToPane(pane)
        case .run(let id): await openWaitingRun(id)
        case nil: break
        }
    }

    /// ⌘L: makes the next pane that needs you active and focused. Returns false when no other pane needs you.
    @discardableResult
    public func goToNextPaneThatNeedsYou(elsewhere: Bool = false) -> Bool {
        guard let pane = nextPaneThatNeedsYou(elsewhere: elsewhere), pane != workspace.focusedPane else { return false }
        goToPane(pane)
        return true
    }

    // MARK: Ready to merge (ticket 107)

    /// ⌘⇧L: the next worktree at the Ready to merge stage after the current one, in sidebar order, round
    /// to the start. The current worktree is the one that you selected, else the one that holds the
    /// focused pane. Nil when no worktree is ready.
    public func nextReadyWorktree() -> SidebarModel.WorktreeRow? {
        let sidebar = self.sidebar
        let current = selectedWorktree ?? workspace.focusedPane.flatMap { sidebar.checkout(holding: $0)?.worktree?.id }
        let next = AttentionCycle.next(order: sidebar.orderedWorktrees.map(\.id), matching: Set(sidebar.readyToMerge.map(\.id)),
                                       after: current)
        return sidebar.readyToMerge.first { $0.id == next }
    }

    /// ⌘⇧L and a click on the "Ready to merge" row: goes to the next ready worktree, in any plot, and
    /// opens its PR popover. Returns false when no worktree is ready, and while a merge or a worktree start runs.
    @discardableResult
    public func goToNextReadyWorktree() -> Bool {
        // A merge or a worktree start keeps the keys on its sheet, and the popover would take them.
        guard !sheetHoldsWindow, let row = nextReadyWorktree() else { return false }
        goToWorktree(row.id)
        openPullRequest(row.id)
        return true
    }

    /// Makes the plot of the worktree active and selects its row. A worktree with a pane gives its first
    /// pane in the sidebar the focus, and that pane is the selection then. Does nothing for a worktree
    /// that the sidebar does not list.
    public func goToWorktree(_ id: String) {
        let sidebar = self.sidebar
        guard let row = sidebar.orderedWorktrees.first(where: { $0.id == id }) else { return }
        if let pane = sidebar.tree(of: row.plotID).allCheckouts.first(where: { $0.id == id })?.panes.first {
            goToPane(pane.id)  // The focus of the pane ends any selection of a worktree row.
        } else {
            if workspace.activePlotID != row.plotID { activate(plot: row.plotID) }
            selectedWorktree = id
        }
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
        let plotName = workspace.spec(of: pane).flatMap { name(of: $0.space) } ?? ""
        return AttentionBanner(pane: pane, plotName: plotName, paneTitle: workspace.title(of: pane, terminalTitles: terminalTitles),
                               reason: workspace.session(of: pane)?.waitsOn)
    }

    /// The name that the window shows for a space: "Home", or the plot name. Nil for a plot that is gone.
    public func name(of space: Space) -> String? {
        switch space {
        case .home: Space.homeName
        case .plot(let id): plots.first { $0.id == id }?.name ?? archivedPlots.first { $0.id == id }?.name
        }
    }

    /// The pane's process exited. A seeded pane stays and shows "Session ended".
    public func paneExited(_ pane: PaneID) {
        workspace.processExited(pane)
        startPrompts.removeValue(forKey: pane)?.wait.cancel()
        // A worktree pane that ends may have lost its folder. Read the list again for the ended note.
        if workspace.spec(of: pane)?.worktree != nil { Task { await reloadWorktrees() } }
    }

    /// "Session ended", Resume: `loam resume` of the pane's last session, in the same place.
    /// Nothing happens while the process runs, or when no session started in the pane.
    public func resumeSession(in pane: PaneID) {
        guard let spec = workspace.spec(of: pane), spec.kind == .session,
              let session = workspace.session(of: pane), session.exited, session.started,
              let id = session.sessionID else { return }
        workspace.restartPane(pane, with: resumeSpec(in: spec.space, sessionID: id, repo: spec.repo, worktree: spec.worktree,
                                                     plotFolder: spec.inPlotFolder))
    }

    /// "Session ended", New session: `loam start` with a new session ID, in the same place and repo.
    public func newSession(in pane: PaneID) {
        guard let spec = workspace.spec(of: pane), spec.kind == .session,
              workspace.session(of: pane)?.exited == true else { return }
        workspace.restartPane(pane, with: newSessionSpec(in: spec.space, repo: spec.repo, worktree: spec.worktree,
                                                         plotFolder: spec.inPlotFolder))
    }

    /// The pane that runs or ran a session, for the actor label in the review.
    public func paneRef(forSession id: String) -> PaneRef? {
        guard let pane = workspace.pane(forSession: id), let spec = workspace.spec(of: pane) else { return nil }
        return PaneRef(id: pane, name: name(of: spec.space).map { "\(spec.title) \u{00B7} \($0)" } ?? spec.title)
    }

    /// Makes the pane's space active and focuses the pane. The switcher counts it as a use.
    public func goToPane(_ pane: PaneID) {
        guard let space = workspace.spec(of: pane)?.space else { return }
        if space != workspace.activeSpace { show(space) }
        focus(pane)
    }

    /// Ghostty `equalize_splits`, on the selected tab of the active space.
    public func equalizeSplits() {
        guard let space = workspace.activeSpace else { return }
        workspace.equalize(in: space)
    }

    /// Ghostty `resize_split`, on the focused pane. `delta` is a fraction of the split (0.05 is 5 percent).
    public func resizeSplit(_ direction: SplitTree.ResizeDirection, by delta: Double) {
        guard let space = workspace.activeSpace, let tab = workspace.selectedTab(of: space) else { return }
        workspace.resize(in: space, pane: tab.focused, toward: direction, by: delta)
    }

    /// A divider drag: sets the ratio of the split at `path` in the selected tab.
    public func setSplitRatio(_ ratio: Double, at path: [Int]) {
        guard let space = workspace.activeSpace else { return }
        workspace.setRatio(ratio, at: path, in: space)
    }

    public func selectTab(number: Int) {
        guard let space = workspace.activeSpace else { return }
        workspace.selectTab(number: number, in: space)
    }

    /// A click on a tab of the tab bar: selects by position, so tab 9 of 12 is the 9th tab.
    public func selectTab(index: Int) {
        guard let space = workspace.activeSpace else { return }
        workspace.selectTab(index: index, in: space)
    }

    /// A drag in the tab bar (ticket 98): moves the tab at `from` to `to` in the active space. The
    /// selected tab stays selected, and ⌘1 to ⌘9 follow the new order.
    public func moveTab(from: Int, to: Int) {
        guard let space = workspace.activeSpace else { return }
        workspace.moveTab(from: from, to: to, in: space)
    }

    public func nextTab() { if let space = workspace.activeSpace { workspace.nextTab(in: space) } }
    public func previousTab() { if let space = workspace.activeSpace { workspace.previousTab(in: space) } }

    public func focus(_ pane: PaneID) {
        endWorktreeSelection()
        page = nil
        let changed = workspace.spec(of: pane).flatMap { workspace.selectedTab(of: $0.space) }?.focused != pane
        workspace.focus(pane)
        if changed { useTimes?.record(SwitcherItem.paneKey(pane.uuidString)) }
    }

    /// The terminal reports a new title for the pane.
    public func setTerminalTitle(_ title: String, of pane: PaneID) {
        // A shell reports its title at its prompt, so text that waits for the shell can go in. It goes
        // in on the next turn, not inside the call of the terminal that reports the title.
        if let wait = shellWaits.removeValue(forKey: pane) {
            wait.cancel()
            Task { deliverUnsentText() }
        }
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

    /// Ghostty `goto_split`, in the selected tab of the active space.
    public func focusPane(_ step: AppCommand.PaneStep) {
        guard let space = workspace.activeSpace else { return }
        endWorktreeSelection()
        switch step {
        case .next: workspace.focusNextPane(in: space)
        case .previous: workspace.focusPreviousPane(in: space)
        case .left: workspace.focusPane(toward: .left, in: space)
        case .right: workspace.focusPane(toward: .right, in: space)
        case .up: workspace.focusPane(toward: .up, in: space)
        case .down: workspace.focusPane(toward: .down, in: space)
        }
    }

    /// Ghostty `close_tab`: closes the selected tab of the active space at once. The window asks
    /// first when a session in the tab is mid-turn (`ClosePrompt`). Returns false when there is no tab.
    @discardableResult
    public func closeTab() -> Bool {
        guard let space = workspace.activeSpace, workspace.selectedTab(of: space) != nil else { return false }
        workspace.closeSelectedTab(in: space)
        return true
    }

    /// The close button of a tab (ticket 96): closes that tab of the active space at once, selected
    /// or not, and leaves the selection on the same tab. Returns false when the space has no such tab.
    @discardableResult
    public func closeTab(_ id: UUID) -> Bool {
        guard let space = workspace.activeSpace, workspace.tabs(of: space).contains(where: { $0.id == id }) else { return false }
        workspace.closeTab(id, in: space)
        return true
    }

    /// Closes the focused pane of the active space. Returns false when there is none.
    @discardableResult
    public func closeFocusedPane() -> Bool {
        guard let pane = workspace.focusedPane else { return false }
        workspace.closePane(pane)
        return true
    }

    // MARK: Worktrees

    /// The checks of a worktree, from the last list.
    public func worktreeStatus(_ id: String) -> WorktreeStatus? {
        worktrees.values.joined().first { $0.worktree.id == id }
    }

    // MARK: The PR popover (ticket 109)

    /// Opens the PR popover for a worktree and asks GitHub about it (`refreshWorktree`), so the popover
    /// shows the state now. The popover shows the last state until the answer comes. A popover that is open
    /// moves to the worktree. Returns false when the worktree is unknown, and while a merge or a worktree start runs.
    @discardableResult
    public func openPullRequest(_ id: String, anchor: PopoverAnchor = .actionBar) -> Bool {
        // The popover would open under a sheet that merges or makes a worktree and take its keys, so a merge or a start that
        // fails leaves the sheet with none.
        guard !sheetHoldsWindow, worktreeStatus(id) != nil else { return false }
        prPopover.open(id, anchor: anchor)
        worktreeRefresh(id)
        return true
    }

    public func closePullRequest() { prPopover.close() }

    /// Opens the passed checks in the open popover, or closes them (ticket 116). A click that comes after a refresh
    /// took the row away opens nothing, so a row that comes back later shows the list closed.
    public func togglePassedChecks() {
        guard let id = prPopover.worktreeID, let status = worktreeStatus(id),
              !PRPopoverContent(status).passedChecks.isEmpty else { return }
        prPopover.togglePassedChecks()
    }

    /// Keeps the popover in step with the row of its worktree. A worktree that left the list (a land removed it,
    /// or the folder and the record are gone) closes the popover, because it has nothing to show. A row that has
    /// no passed checks to show now (a refresh found no failed check) closes the passed list (ticket 116).
    private func followPullRequestRow() {
        guard let id = prPopover.worktreeID else { return }
        guard let status = worktreeStatus(id) else { return prPopover.close() }
        let content = PRPopoverContent(status)
        if content.passedChecks.isEmpty { prPopover.hidePassedChecks() }
        // A worktree that got its PR has no Goal row to edit (ticket 115).
        if content.goal == nil { prPopover.cancelGoalEdit() }
    }

    /// Re-run failed: `loam worktree rerun`. The popover shows what GitHub did, then asks about the
    /// worktree again, so the checks show as running. Does nothing when no popover is open, or while a
    /// button runs for its worktree.
    public func rerunFailedChecks() async {
        await runPullRequestAction(.rerunFailed) { plot, id in
            PRActionNote.rerun(try await self.client.worktreeRerun(plot: plot, worktree: id))
        }
    }

    /// Update branch: `loam worktree update`. As `rerunFailedChecks`.
    public func updateBranch() async {
        await runPullRequestAction(.updateBranch) { plot, id in
            PRActionNote.update(try await self.client.worktreeUpdate(plot: plot, worktree: id))
        }
    }

    /// Runs a button for the worktree of the popover. The command goes on when the popover closes or shows
    /// another worktree. Its note shows only in a popover that shows the worktree when it ends.
    private func runPullRequestAction(_ action: PRSecondaryAction, _ run: (_ plot: String, _ worktree: String) async throws -> String) async {
        guard let id = prPopover.worktreeID, let plot = worktreeStatus(id)?.worktree.plotID,
              prPopover.begin(action, for: id) else { return }
        do {
            prPopover.end(id, note: try await run(plot, id))
        } catch {
            // The popover shows the refusal where the button is. When it no longer shows the worktree, the
            // error bar of the window says it.
            if !prPopover.end(id, note: Self.message(for: error)) { report(error) }
            return
        }
        // GitHub changed the PR, so the app asks about it again, also when nobody sees the popover.
        await refreshWorktree(id, afterChange: true)
    }

    // MARK: Send to session (ticket 110)

    /// What Send to session does for the worktree now. Nil for a stage that no prompt fixes, and for an unknown
    /// worktree.
    public func sendPlan(for id: String) -> SendPlan? {
        guard let status = worktreeStatus(id), let prompt = FixPrompt(status) else { return nil }
        return SendPlan(prompt: prompt, worktree: status.worktree, in: workspace, links: SessionLinks(worktrees),
                        lastFocus: lastFocus, titles: terminalTitles)
    }

    /// True when the checks of the worktree failed. The Worktree actions menu and ⌘J then offer Send failures
    /// to session.
    public func canSendFailures(_ id: String) -> Bool {
        worktreeStatus(id).flatMap(FixPrompt.init)?.kind == .failures
    }

    /// The primary button of the PR popover for a worktree that needs a fix. It types the prompt into the
    /// session of the worktree and focuses the session, copies the prompt when Loam cannot type, or starts a
    /// session that gets the prompt after its `SessionStart`. Returns the plan that ran. Nil for a stage that no
    /// prompt fixes.
    @discardableResult
    public func sendToSession(_ id: String) -> SendPlan? {
        guard let plan = sendPlan(for: id), let worktree = worktreeStatus(id)?.worktree else { return nil }
        switch plan.step {
        case .type(let pane):
            closePullRequest()
            goToPane(pane)
            // A second click finds the prompt in the input already, and Loam does not type it twice.
            if workspace.session(of: pane)?.loamPrompt != plan.prompt.text {
                guard typePrompt(plan.prompt.text, into: pane) else { return plan }
            }
            onPromptTyped?(pane)
            if let toast = plan.toast { onToast?(toast, .done) }
        case .copy:
            copyText(plan.prompt.text)
            prPopover.say("Copied the prompt.")
        case .start:
            closePullRequest()
            let before = Set(workspace.allPaneIDs)
            openWorktreePane(worktree)
            guard let pane = workspace.focusedPane, !before.contains(pane) else {
                onToast?(SendPlan.startNoPaneToast, .notice)
                return plan
            }
            let wait = sessionStartWait
            startPrompts[pane] = (id, Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                self?.sessionDidNotStart(pane)
            })
        }
        return plan
    }

    /// Send failures to session from the Worktree actions menu or ⌘J. When Loam cannot type, the PR popover
    /// opens instead, so you see why, and its button copies the prompt.
    public func sendFromMenu(_ id: String) {
        guard let plan = sendPlan(for: id) else { return }
        if case .copy = plan.step { openPullRequest(id) } else { sendToSession(id) }
    }

    /// Types the prompt into the input of the pane, with no Return, and keeps it as the prompt of the pane.
    /// False when the terminal refuses the text, and `lastError` says why.
    private func typePrompt(_ prompt: String, into pane: PaneID) -> Bool {
        do { try type(prompt, into: pane) } catch {
            report(error)
            return false
        }
        workspace.prompted(prompt, in: pane)
        return true
    }

    /// The first `SessionStart` of a session that Start session with prompt opened. Loam types the prompt that
    /// the worktree needs now. The pane does not take the focus, since you may work in another pane by now. When
    /// Loam cannot type, a notice says why.
    private func typeStartPrompt(into pane: PaneID) {
        guard let start = startPrompts.removeValue(forKey: pane) else { return }
        start.wait.cancel()
        guard let status = worktreeStatus(start.worktree) else {
            onToast?(SendPlan.startLostWorktreeToast, .notice)
            return
        }
        guard let prompt = FixPrompt(status) else {
            onToast?(SendPlan.startNotTypedToast(nil), .notice)
            return
        }
        let step = workspace.session(of: pane).map { SendPlan.step(for: pane, session: $0, prompt: prompt.text) } ?? .start
        guard step == .type(pane) else {
            onToast?(SendPlan.startNotTypedToast(step), .notice)
            return
        }
        // `typePrompt` reports its own error.
        guard typePrompt(prompt.text, into: pane) else { return }
        onToast?(SendPlan.toastForNewSession(prompt.kind), .done)
    }

    /// No `SessionStart` came in `sessionStartWait`, such as when the setup command waits for an answer. Loam
    /// types nothing into the session, and a toast says so. The PR popover does not open, because the pane can
    /// still show the setup question, and Return would then run Copy prompt.
    private func sessionDidNotStart(_ pane: PaneID) {
        guard let id = startPrompts.removeValue(forKey: pane)?.worktree else { return }
        onToast?(SendPlan.notStartedToast(worktree: worktreeStatus(id)?.worktree.name), .notice)
    }

    // MARK: The PR of a pane

    /// The worktree that the pane shows under: the worktree that it runs in, or the one that its session works
    /// in (TAS-55). The pane header shows its branch, and the chip its PR.
    public func shownWorktree(of pane: PaneID) -> WorktreeRef? {
        workspace.shownWorktree(of: pane, links: SessionLinks(worktrees))
    }

    /// The PR of the worktree that the pane shows under, as the action bar chip and the pane header show it.
    /// Nil for a pane in the main checkout or in Home, and for a worktree with no PR or with no folder. The
    /// ✎ mark of work that is not pushed is a mark of the sidebar, not a PR.
    public func pullRequestMark(of pane: PaneID) -> StageMark? {
        guard let id = shownWorktree(of: pane)?.id, let status = worktreeStatus(id), status.pr != nil,
              let mark = StageMark(status), mark.number != nil else { return nil }
        return mark
    }

    /// The worktree that the focused pane shows under (`shownWorktree(of:)`). Nil for the main checkout and
    /// for Home.
    public var focusedWorktree: WorktreeRef? {
        workspace.focusedPane.flatMap(shownWorktree(of:))
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

    /// Opens a tab in the worktree with a seeded session. `loam start --worktree` runs the setup
    /// command first, and asks on the terminal when the command is new or changed.
    public func openWorktreePane(_ worktree: Worktree, kind: PaneSpec.Kind = .session) {
        if workspace.activePlotID != worktree.plotID { activate(plot: worktree.plotID) }
        // A plot that is not in the list does not become active. The tab must not open in another space.
        guard workspace.activePlotID == worktree.plotID else { return }
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

    // MARK: Ship state (ticket 108)

    /// The command that Sign in types into a shell. It is not sent: you read it and press Return.
    public static let signInCommand = "gh auth login"

    /// The notices for the Worktrees section of a plot, in a fixed order, without the dismissed ones.
    public func shipNotices(for plot: String) -> [ShipNotice] {
        ShipNotice.current(for: worktrees[plot] ?? [], dismissed: dismissedShipNotices)
    }

    public func dismiss(_ notice: ShipNotice) {
        dismissedShipNotices.insert(notice)
    }

    /// Settings opened: asks again about `gh` for the active plot, since you may have installed it or
    /// signed in by now. Home has no Worktrees section, so it asks nothing.
    public func checkGitHub() async {
        guard let plot = workspace.activePlotID else { return }
        await shipRefresh.refresh(plot)
    }

    /// Sign in, on the callout: a shell tab in the active plot with `gh auth login` typed and not sent.
    /// The plot refreshes when you close that pane.
    public func signInToGitHub() async {
        guard let plot = workspace.activePlotID else { return }
        let before = Set(workspace.allPaneIDs)
        await openShellTab()
        guard let pane = workspace.focusedPane, !before.contains(pane) else { return }
        signInPanes[pane] = plot
        do { try typeAtPrompt(Self.signInCommand, into: pane) } catch { report(error) }
    }

    /// Types text into a pane as a paste with no Return, as soon as the pane has a terminal.
    /// The window builds the terminal of a new pane when it renders, so the text can wait for that.
    /// Throws `PaneTextError.lineBreakInside` for text that has a line break inside it, and types
    /// nothing. The line breaks at the end of the text are dropped (`PaneText.withoutReturn`).
    public func type(_ text: String, into pane: PaneID) throws {
        unsentText[pane, default: []].append(try PaneText.withoutReturn(text))
        deliverUnsentText()
    }

    /// Types text into a shell pane once the shell shows its first prompt. The terminal driver echoes
    /// text that comes sooner, so it would show twice. A shell with shell integration reports its title
    /// at its prompt (`setTerminalTitle`), which ends the wait. A shell that reports none gets the text
    /// after `shellWait`. It throws for the text that `type(_:into:)` refuses.
    public func typeAtPrompt(_ text: String, into pane: PaneID) throws {
        guard terminalTitles[pane] == nil else { return try type(text, into: pane) }  // It showed its prompt already.
        unsentText[pane, default: []].append(try PaneText.withoutReturn(text))
        guard shellWaits[pane] == nil else { return }
        let wait = shellWait
        shellWaits[pane] = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.shellWaits[pane] = nil
            self?.deliverUnsentText()
        }
    }

    /// Types the text that waits for a pane, in the order it came, into each pane that has a terminal now.
    /// The window calls it after each render. A shell that has not shown a prompt keeps its text. Text
    /// that the terminal refuses is dropped, and `lastError` says why.
    public func deliverUnsentText() {
        for (pane, texts) in unsentText where shellWaits[pane] == nil {
            var rest = texts
            while let next = rest.first {
                do { guard try typeIntoPane(pane, next) else { break } } catch { report(error) }
                rest.removeFirst()
            }
            unsentText[pane] = rest.isEmpty ? nil : rest
        }
    }

    /// The text for a pane that closed never arrives. A plot whose Sign in pane closed refreshes, since
    /// the sign-in may be done. A pane that closed gets no prompt from Send to session, and its focus time goes.
    private func closedShipPanes() {
        let open = Set(storedWorkspace.allPaneIDs)
        unsentText = unsentText.filter { open.contains($0.key) }
        lastFocus = lastFocus.filter { open.contains($0.key) }
        for pane in shellWaits.keys where !open.contains(pane) { shellWaits.removeValue(forKey: pane)?.cancel() }
        for pane in startPrompts.keys where !open.contains(pane) { startPrompts.removeValue(forKey: pane)?.wait.cancel() }
        let closed = signInPanes.filter { !open.contains($0.key) }
        for pane in closed.keys { signInPanes[pane] = nil }
        for plot in Set(closed.values) { Task { await shipRefresh.refresh(plot) } }
    }

    // MARK: Plot lifecycle (spec section 10)

    /// The question before archive, or nil when no session in the plot asks.
    /// It uses the `ClosePrompt` rule, so ticket 32 adds "needs you" in one place.
    public func archivePrompt(for plot: String) -> ClosePrompt? {
        ClosePrompt.make(.archive, closing: workspace.livePaneIDs(of: .plot(plot)), in: workspace)
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
                    resumeSpec(in: .plot(id), sessionID: $0, repo: spec.repo, worktree: spec.worktree, plotFolder: spec.inPlotFolder)
                } ?? spec
            case .shell:
                newShellSpec(in: .plot(id), folder: workspace.folder(of: pane), worktree: spec.worktree)
            }
        }
        // The panes and the active plot change in one step, so the window never shows a waiting plot.
        // The index is read again here: a feed reload can change the list during the await.
        let index = plots.firstIndex(where: { $0.id == id }) ?? plots.count
        let rest = plots.filter { $0.id != id }
        if wasActive {
            if panel.visible { review.markSeen(plot: id) }
            let neighbour: Space = (rest.indices.contains(index) ? rest[index].id : rest.last?.id).map { .plot($0) } ?? .home
            next.activate(neighbour)
            useTimes?.record(SwitcherItem.key(of: neighbour))
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
