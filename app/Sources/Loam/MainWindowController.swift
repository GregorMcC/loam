import AppKit
import LoamKit
import OSLog
import SwiftUI

/// The one window. AppKit owns the window and the pane views. A SwiftUI sidebar sits in an `NSHostingController`.
/// `render()` turns the workspace into views: it creates a view per new pane, closes the views of gone panes,
/// shows the selected tab of the active plot, and keeps every other plot's views alive but hidden.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let model: AppModel
    private let factory: PaneViewFactory
    private let splitController = NSSplitViewController()
    private let tabBar = TabBarView()
    private let sidebarItem: NSSplitViewItem
    let paneArea = PaneAreaView()
    private let panelItem: NSSplitViewItem
    private let columnView: PaneColumnView
    /// Calls `reloadSubtitleBranch` when the main repo's `HEAD` changes (a branch switch in a pane).
    private var headWatcher: HeadWatcher?
    private var collapseObservation: NSKeyValueObservation?
    private var panelObservation: NSKeyValueObservation?
    private var frameObservers: [NSObjectProtocol] = []
    private var activeObservers: [NSObjectProtocol] = []
    /// The unified toolbar's delegate (ticket 68).
    private var toolbar: WindowToolbar?
    /// True once quit has closed the panes. Nothing renders after that, so no pane starts again.
    private var quitting = false
    let switcherHost: NSHostingView<SwitcherView>
    /// The bottom action bar and its actions menu (ticket 89).
    let actionBar = ActionBarModel()
    /// The plot and the pane that the open actions menu names.
    var actionsContext: ActionsContext?
    private(set) var barHost: NSHostingView<ActionBarView>!
    private(set) var actionsHost: NSHostingView<ActionsMenuView>!
    let panelController: NSHostingController<PlotPanelView>

    init(model: AppModel, factory: PaneViewFactory) {
        self.model = model
        self.factory = factory

        let sidebarController = NSHostingController(rootView: SidebarView(model: model))
        sidebarController.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        let contentController = NSViewController()
        columnView = PaneColumnView(tabBar: tabBar, paneArea: paneArea)
        contentController.view = columnView
        splitController.splitView = LoamSplitView()
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(NSSplitViewItem(viewController: contentController))
        panelController = NSHostingController(rootView: PlotPanelView(model: model.panel, review: model.review, app: model))
        panelController.sizingOptions = []
        // A plain split item, not an inspector: macOS 26 puts an inspector on a glass layer, which
        // made the panel a lighter tone than the chrome ground, and opaque in a translucent window.
        // The panel paints the chrome ground itself. It runs the full height of the window: the
        // action bar belongs to the well, and ends where the well ends.
        panelItem = NSSplitViewItem(viewController: panelController)
        panelItem.holdingPriority = NSLayoutConstraint.Priority(260)  // The column takes a window resize, as with an inspector.
        panelItem.minimumThickness = 260
        panelItem.maximumThickness = 520
        panelItem.canCollapse = false  // Only ⌘I changes it, so `panel.visible` stays true to the view.
        panelItem.isCollapsed = true
        splitController.addSplitViewItem(panelItem)

        switcherHost = NSHostingView(rootView: SwitcherView(model: model.switcher))
        switcherHost.sizingOptions = []
        switcherHost.isHidden = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Loam"
        // Ticket 68: a native frame. The sidebar is the system's glass sidebar, full height under the
        // window buttons. A unified toolbar names the plot (title) and its main repo and branch
        // (subtitle). The frame behind the glass is bedrock (`LoamSplitView`), so it takes the terminal theme.
        window.backgroundColor = LoamTheme.horizonO
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.contentViewController = splitController
        window.setFrameAutosaveName("")  // Restore (ticket 29) owns the frame.
        // Setting the content view controller shrinks the window to the view's fitting size (188 by 50
        // with no saved frame), so the first launch needs the size set again.
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        super.init(window: window)

        headWatcher = HeadWatcher { [weak self] in
            self?.reloadSubtitleBranch()
            // The sidebar's main checkout row names the branch too (ticket 71).
            Task { await self?.model.rereadMainCheckoutBranches() }
        }
        let toolbar = WindowToolbar(model: model, target: self, newSession: #selector(newSession(_:)),
                                    plotPanel: #selector(togglePlotPanel(_:)))
        self.toolbar = toolbar
        window.toolbar = toolbar.makeToolbar()
        window.delegate = self
        restoreWindowState(window)
        // Done, unread clears when you look at a pane while Loam is frontmost (spec 8.4). A window that
        // is minimized or covered does not count, so a banner shows for it.
        model.isFrontmost = { [weak window] in
            guard let window else { return false }
            return NSApp.isActive && window.isVisible && window.occlusionState.contains(.visible)
        }
        let seen: [(Notification.Name, NSWindow?)] = [
            (NSApplication.didBecomeActiveNotification, nil), (NSWindow.didChangeOcclusionStateNotification, window),
        ]
        activeObservers = seen.map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.frontmostChanged() }
            }
        }
        model.onWorkspaceChange = { [weak self] in self?.render() }
        model.onTitleChange = { [weak self] in
            guard let self, !self.quitting else { return }
            self.updatePaneLabels()
        }
        // A pane that waited for its old view to close gets its new view now.
        views.onCloseFinished = { [weak self] pane in
            guard let self, self.model.workspace.livePaneIDs.contains(pane) else { return }
            self.render()
        }
        connectSwitcher()
        installActionBar()
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncCollapse() }
        }
        panelObservation = panelItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncNeighbours() }
        }
        syncNeighbours()
        render()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setActionHosts(bar: NSHostingView<ActionBarView>, menu: NSHostingView<ActionsMenuView>) {
        barHost = bar
        actionsHost = menu
        let split = splitController.splitView as? LoamSplitView
        split?.onBarLayout = { [actionBar] inset in
            if actionBar.menu.trailingInset != inset { actionBar.menu.trailingInset = inset }
        }
        split?.install(bar: bar, overlay: menu, switcher: switcherHost, barHeight: ActionBarView.height)
    }

    /// The room under the well: the action bar.
    func columnBottomInset(_ height: CGFloat) { columnView.bottomInset = height }

    private func syncCollapse() {
        model.sidebarCollapsed = sidebarItem.isCollapsed
        syncNeighbours()
    }

    /// The well keeps a margin of frame on each side where no sidebar or panel touches it (ticket 88).
    private func syncNeighbours() {
        columnView.setNeighbours(sidebar: !sidebarItem.isCollapsed, panel: !panelItem.isCollapsed)
    }

    // MARK: Restore and quit (spec 8.5)

    /// Puts back the saved frame, sidebar, and plot panel, and keeps the frame in the model.
    /// A frame that does not show at least 100 by 40 points on one screen now is skipped.
    private func restoreWindowState(_ window: NSWindow) {
        if let saved = model.restoredWindow {
            let onScreen = { (frame: CGRect) in
                NSScreen.screens.contains { $0.visibleFrame.intersection(frame).width >= 100 && $0.visibleFrame.intersection(frame).height >= 40 }
            }
            if let frame = saved.rect, onScreen(frame) {
                window.setFrame(frame, display: false)
            }
            sidebarItem.isCollapsed = saved.sidebarCollapsed
            model.sidebarCollapsed = saved.sidebarCollapsed
            if saved.panelOpen {
                model.setPanelVisible(true)
                panelItem.isCollapsed = false
            }
        }
        let center = NotificationCenter.default
        let save: @Sendable (Notification) -> Void = { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window, !window.inLiveResize else { return }
                self.model.windowFrame = window.frame
            }
        }
        frameObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification]
            .map { center.addObserver(forName: $0, object: window, queue: .main, using: save) }
        model.windowFrame = window.frame
    }

    /// The quit question, or nil when no session is mid-turn.
    var quitPrompt: ClosePrompt? {
        ClosePrompt.make(.quit, closing: model.workspace.livePaneIDs, in: model.workspace)
    }

    /// Quit: asks first when a session is mid-turn, then closes every pane. `done(true)` runs once
    /// every pane has closed, `done(false)` after Cancel.
    func requestQuit(_ done: @escaping @MainActor (Bool) -> Void) {
        confirm(quitPrompt, onCancel: { done(false) }) { [weak self] in
            guard let self else { return done(true) }
            self.closeEveryPane { done(true) }
        }
    }

    /// Saves the layout one last time, stops the writes, and closes every pane with the safe order
    /// (`close(completion:)` through the factory). The workspace keeps its panes, so `state.json`
    /// lists them for the next launch. `done` runs once, on a later main run loop pass, and at the
    /// latest after `quitTimeout`, so a close that never completes cannot stop the quit.
    func closeEveryPane(_ done: @escaping @MainActor () -> Void) {
        quitting = true
        model.prepareForQuit()
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            done()
        }
        for pane in paneArea.paneIDs {
            guard let container = paneArea.detach(pane) else { continue }
            close(container, of: pane)
        }
        // Quit also waits for the closes that started before it (archive, resume).
        guard views.isClosingAny else { DispatchQueue.main.async { finish() }; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitTimeout) { finish() }
        views.whenClosesFinish { DispatchQueue.main.async { finish() } }
    }

    /// The safe close gives up on a pane after 5 s (`SafeClose`). Quit waits a little longer.
    static let quitTimeout: TimeInterval = 8

    /// The window close button quits through the same path as ⌘Q, so the question and the safe close run.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    /// Runs `action` at once when `prompt` is nil. Else it shows the question as a sheet and runs
    /// `action` on the confirm button, or `onCancel` on Cancel.
    private func confirm(_ prompt: ClosePrompt?, onCancel: (@MainActor () -> Void)? = nil,
                         then action: @escaping @MainActor () -> Void) {
        guard let prompt, let window else { return action() }
        // One question at a time. A second ⌘W or ⌘Q while one shows does nothing.
        guard window.attachedSheet?.identifier != Self.closePromptID else { onCancel?(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: prompt.confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.identifier = Self.closePromptID
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { action() } else { onCancel?() }
        }
    }

    static let closePromptID = NSUserInterfaceItemIdentifier("dev.loam.close-prompt")

    // MARK: Render

    private var rendering = false
    private var renderAgain = false
    /// Which views to close and build. A pane's new view waits for the close of its old view (ticket 61).
    private let views = PaneViewPlan()

    /// A change during a render (focus can change the workspace) runs one more pass, so the views never go stale.
    func render() {
        if quitting { return }
        if rendering { renderAgain = true; return }
        rendering = true
        defer { rendering = false }
        repeat {
            renderAgain = false
            renderOnce()
        } while renderAgain
    }

    private func renderOnce() {

        let workspace = model.workspace
        // A restored plot's panes start when the plot is first shown (spec 8.5): only live panes get
        // a view and their labels (`updatePaneLabels`).

        // A restarted pane (resume or a new session) gets a new view under the same ID. So does a pane
        // of an unarchived plot. The new view starts only after the old view's safe close finishes,
        // so two processes never hold one session. The finish renders again.
        for gone in views.toClose(in: workspace) {
            guard let container = paneArea.detach(gone) else { views.forget(gone); continue }
            close(container, of: gone)
        }
        for id in views.toBuild(in: workspace) {
            guard let spec = workspace.spec(of: id) else { continue }
            views.didBuild(id, in: workspace)
            let container = PaneContainerView(paneID: id, content: factory.makeView(for: spec, id: id))
            container.onActivate = { [weak model] in model?.focus($0) }
            container.onResume = { [weak model] in model?.resumeSession(in: $0) }
            container.onNewSession = { [weak model] in model?.newSession(in: $0) }
            container.onClose = { [weak model] in model?.closePane($0) }
            paneArea.add(container)
        }

        let active = workspace.activePlotID
        let tab = active.flatMap { workspace.selectedTab(of: $0) }
        updatePaneLabels()
        tabBar.onSelect = { [weak model] index in model?.selectTab(index: index) }
        tabBar.onMove = { [weak model] from, to in model?.moveTab(from: from, to: to) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onNewSession = { [weak self] in self?.newSession(nil) }
        columnView.setTabBarShown(!tabBar.items.isEmpty)
        paneArea.onDividerDrag = { [weak model] path, ratio in model?.setSplitRatio(ratio, at: path) }
        paneArea.show(tab?.tree)
        paneArea.layoutSubtreeIfNeeded()

        window?.title = model.sidebar.windowTitle
        refreshSubtitle()
        closeActionsMenuIfContextChanged()
        // The open switcher keeps the keyboard. A pane event or a feed update must not move it to the terminal.
        if !model.switcher.isOpen, !actionBar.menu.isOpen, let focused = tab?.focused, let container = paneArea.container(for: focused) {
            window?.makeFirstResponder(container.focusTarget)
        }
    }

    /// The pane headers and the tab labels. A terminal title change runs only this (ticket 71), so it
    /// does not move the focus. A pane shows its header only in a split tab (`Workspace.showsHeader`).
    private func updatePaneLabels() {
        let workspace = model.workspace
        let active = workspace.activePlotID
        let focused = active.flatMap { workspace.selectedTab(of: $0) }?.focused
        let titles = model.terminalTitles
        for id in workspace.livePaneIDs {
            guard let spec = workspace.spec(of: id), let container = paneArea.container(for: id) else { continue }
            container.update(title: workspace.title(of: id, terminalTitles: titles), state: workspace.state(of: id) ?? .running,
                             focused: id == focused, branch: spec.worktree?.branch, attention: workspace.attention(of: id),
                             showsHeader: workspace.showsHeader(id))
            let session = workspace.session(of: id)
            container.showEnded(spec.kind == .session && session?.exited == true, canResume: session?.started == true,
                              note: model.endedNote(of: id))
        }
        tabBar.update(TabBarModel(workspace: workspace, plot: active, titles: titles, arriving: model.arrivingPanes()).items)
        let plotName = model.plots.first { $0.id == active }?.name ?? ""
        let paneLabel = focused.map { workspace.title(of: $0, terminalTitles: titles) } ?? ""
        if actionBar.plotID != active { actionBar.plotID = active }
        if actionBar.plotName != plotName { actionBar.plotName = plotName }
        if actionBar.paneLabel != paneLabel { actionBar.paneLabel = paneLabel }
    }

    // MARK: Subtitle and chrome (ticket 68)

    /// The plot and the plot list that the subtitle shows.
    private var subtitlePlot: String?
    private var subtitlePlots: [PlotSummary] = []
    /// The main repo that the subtitle shows and the watcher watches.
    private var subtitleRepo: String?
    /// Counts the branch reads, so a late read of an old branch is dropped.
    private var subtitleRead = 0

    /// The subtitle: the main repo's folder name and its branch. Empty for a plot with no repo.
    /// It finds the repo again when the active plot or the plot list changes.
    private func refreshSubtitle() {
        let plot = model.workspace.activePlotID
        guard plot != subtitlePlot || model.plots != subtitlePlots else { return }
        subtitlePlot = plot
        subtitlePlots = model.plots
        guard let plot else { setSubtitleRepo(nil); return }
        Task { [weak self, client = model.client] in
            let repo = try? await client.show(plot: plot).repos.first(where: \.main)
            guard let self, self.subtitlePlot == plot else { return }
            self.setSubtitleRepo(repo?.path)
        }
    }

    private func setSubtitleRepo(_ path: String?) {
        guard path != subtitleRepo else { return }
        subtitleRepo = path
        headWatcher?.watch(repo: path)
        window?.subtitle = ""
        reloadSubtitleBranch()
        // The watcher watched another repo until now, so this repo's main checkout row can be old.
        Task { await model.rereadMainCheckoutBranches() }
    }

    /// Reads the repo off the main actor (a stalled mount must not freeze the UI), then sets the
    /// subtitle here. A result for a repo that is no longer shown is dropped.
    private func reloadSubtitleBranch() {
        guard let path = subtitleRepo else { window?.subtitle = ""; return }
        subtitleRead += 1
        let mine = subtitleRead
        Task { [weak self] in
            let text = await Task.detached { RepoLine(path: path).text }.value
            // Reads can finish out of order: only the newest read sets the subtitle.
            guard let self, self.subtitleRepo == path, self.subtitleRead == mine else { return }
            if self.window?.subtitle != text { self.window?.subtitle = text }
        }
    }

    /// The terminal background changed (a Ghostty config load, or a switch to Night or Day). The
    /// chrome surfaces follow it. Nil goes back to Loam's tokens.
    func terminalBackgroundChanged(_ background: UInt32?, opacity: Double) {
        // The palette posts `ChromePalette.didChange`: each AppKit view that sets a layer color
        // observes it. The window appearance follows afterwards (`followTerminal`).
        let surfaces = ChromePalette.shared.follow(terminalBackground: background)
        let translucency = ChromePalette.shared.follow(windowOpacity: opacity)
        guard surfaces || translucency else { return }
        ChromeTick.shared.bump()
        // Views that draw with a dynamic color redraw; no view tree walk.
        window?.viewsNeedDisplay = true
    }

    /// Runs the safe close of a detached pane view and records it in `views` until it finishes.
    private func close(_ container: PaneContainerView, of pane: PaneID) {
        let done = views.closeStarted(pane)
        factory.closeView(container.content) {
            container.removeFromSuperview()
            done()
        }
    }

    /// The content view of a pane, for the driver.
    func paneContent(_ pane: PaneID) -> NSView? { paneArea.container(for: pane)?.content }

    // MARK: Menu actions

    @objc func newPlot(_ sender: Any?) {
        guard let window else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Plot name"
        let alert = NSAlert()
        alert.messageText = "New plot"
        alert.informativeText = "Name the plot."
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [model] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue
            Task { @MainActor in await model.newPlot(named: name) }
        }
    }

    @objc func toggleSidebar(_ sender: Any?) { splitController.toggleSidebar(sender) }
    /// The toolbar's New session button: ⌘T.
    @objc func newSession(_ sender: Any?) { perform(.newTab) }
    /// Shows the plot panel if it is hidden, and asks it to run an action of the actions menu.
    private func panelRequest(_ request: PanelRequest) {
        guard model.workspace.activePlotID != nil else { return }
        if panelItem.isCollapsed { togglePlotPanel(nil) }
        model.panel.request = request
        model.panel.requestPlot = model.workspace.activePlotID
        window?.makeFirstResponder(panelController.view)
    }

    /// ⌘I. The panel loads the active plot while it shows.
    @objc func togglePlotPanel(_ sender: Any?) {
        let show = panelItem.isCollapsed
        if !show { model.panel.request = nil }  // A request the panel could not run does not wait for the next show.
        model.setPanelVisible(show)
        panelItem.animator().isCollapsed = !show
        if show { Task { await model.reloadPanel() } }
    }
    /// ⌘W closes the focused pane. It asks first when the session in it is mid-turn.
    @objc func closePane(_ sender: Any?) {
        guard let plot = model.workspace.activePlotID, let pane = model.workspace.selectedTab(of: plot)?.focused else {
            window?.performClose(sender)
            return
        }
        confirm(ClosePrompt.make(.pane, closing: [pane], in: model.workspace)) { [model] in model.closePane(pane) }
    }

    /// Ghostty `close_tab`: the selected tab. It asks first when a session in the tab is mid-turn.
    private func closeTab() -> Bool {
        guard let plot = model.workspace.activePlotID, let tab = model.workspace.selectedTab(of: plot) else { return false }
        return closeTab(id: tab.id)
    }

    /// The `x` on a tab (ticket 96): the tab at `index`, selected or not, by the same path as ⌘W.
    private func closeTab(at index: Int) {
        guard let plot = model.workspace.activePlotID, model.workspace.tabs(of: plot).indices.contains(index) else { return }
        closeTab(id: model.workspace.tabs(of: plot)[index].id)
    }

    /// Closes one tab. It asks first when a session in the tab is mid-turn, and closes the tab by its
    /// ID after the answer, so the selection stays on the same tab.
    @discardableResult
    private func closeTab(id: UUID) -> Bool {
        guard let plot = model.workspace.activePlotID,
              let tab = model.workspace.tabs(of: plot).first(where: { $0.id == id }) else { return false }
        guard let prompt = ClosePrompt.make(.tab, closing: tab.tree.paneIDs, in: model.workspace) else {
            return model.closeTab(id)
        }
        confirm(prompt) { [model] in model.closeTab(id) }
        return true
    }

    /// Every menu item that carries a `MenuCommand`.
    @objc func performCommand(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MenuCommand else { return }
        perform(item.command)
    }

    // MARK: Commands

    /// Runs the Ghostty config commands (open and reload). The app sets it.
    var onConfigCommand: ((AppCommand) -> Void)?

    /// Runs one command on the active plot: a menu item, a fixed Loam key in a pane, or a Ghostty
    /// action (spec 8.3). Returns false for a command that did nothing, so a performable Ghostty
    /// binding (⌘Z) goes on to the terminal.
    @discardableResult
    func perform(_ command: AppCommand) -> Bool {
        switch command {
        case .newPlot: newPlot(nil)
        case .toggleSidebar: toggleSidebar(nil)
        case .togglePlotPanel: togglePlotPanel(nil)
        case .selectPlot(let number): model.activate(number: number)
        // ⌘T, ⌘D, and ⌘⇧D start a seeded session. A shell starts in the plot's start folder.
        case .newTab: model.openTab(.session)
        case .newShellTab: Task { await model.openShellTab() }
        case .openSettings: showSettings()
        case .newSplit(let axis): model.split(axis, .session)
        case .newShellSplit(let axis): Task { await model.splitShell(axis) }
        case .focusPane(let step): model.focusPane(step)
        case .selectTab(let number): model.selectTab(number: number)
        case .previousTab: model.previousTab()
        case .nextTab: model.nextTab()
        case .lastTab: model.selectTab(number: 9)
        case .closePane: closePane(nil)
        case .closeTab: return closeTab()
        case .equalizeSplits: model.equalizeSplits()
        case .resizeSplit(let direction, let points):
            let size = direction == .left || direction == .right ? paneArea.bounds.width : paneArea.bounds.height
            guard size > 0 else { return false }
            model.resizeSplit(direction, by: points / size)
        case .openConfig, .reloadConfig:
            guard let onConfigCommand else { return false }
            onConfigCommand(command)
        case .quit: NSApp.terminate(nil)
        case .quickSwitcher: model.switcher.open()
        case .quickSwitcherActions: model.switcher.open(actionsOnly: true)
        // ⌘L is a Loam key: with no pane to go to, it does nothing, and the terminal does not get it.
        case .nextPaneThatNeedsYou: model.goToNextPaneThatNeedsYou()
        case .actionsMenu: toggleActionsMenu()
        case .newPlotSession:
            guard let plot = model.workspace.activePlotID else { return false }
            model.openPlotSession(plot)
        case .editBrief: panelRequest(.editBrief)
        case .addLink: panelRequest(.addLink)
        case .addRepo: panelRequest(.addRepo)
        case .archivePlot:
            guard let plot = model.workspace.activePlotID else { return false }
            PlotDialogs.askArchive(plot, model: model)
        case .undo, .redo:
            // Ticket 36 (undo) builds these.
            commandLog.info("No handler yet for \(String(describing: command), privacy: .public)")
            return false
        }
        return true
    }

    // MARK: Settings

    private var settingsWindow: SettingsWindowController?

    /// ⌘, (ticket 81). One settings window: a second ⌘, brings it to the front.
    func showSettings() {
        let controller = settingsWindow ?? SettingsWindowController(settings: model.settings, terminal: model.terminalConfig)
        settingsWindow = controller
        controller.show()
    }

    // MARK: Ghostty config

    /// Shows the errors of a config load as a sheet. A load with no errors shows nothing.
    func showConfigErrors(for outcome: ConfigOutcome, canOpenConfig: Bool) {
        let errors = outcome.errors
        guard let window, !errors.isEmpty else { return }
        let keptLastGood = if case .keptLastGood = outcome { true } else { false }
        if let sheet = window.attachedSheet, sheet.identifier == Self.configErrorsID {
            window.endSheet(sheet)
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Your Ghostty config has errors"
        alert.informativeText = (keptLastGood
            ? "Loam keeps the last config that had no errors.\n\n"
            : "Loam skips the lines with errors.\n\n") + errors.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        if canOpenConfig { alert.addButton(withTitle: "Open Config") }
        alert.window.identifier = Self.configErrorsID
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.onConfigCommand?(.openConfig) }
        }
    }

    private static let configErrorsID = NSUserInterfaceItemIdentifier("dev.loam.config-errors")
}

private let commandLog = Logger(subsystem: "dev.loam.Loam", category: "commands")

/// A split view with `rule` dividers (docs/design: separate regions with a hairline).
final class LoamSplitView: NSSplitView {
    /// The action bar and the actions menu overlay (ticket 89). They are siblings over the split
    /// view, in its superview: the split view controller puts the wrappers of its glass items over
    /// any subview of the split view itself.
    var bar: NSView?
    var overlay: NSView?
    /// Called with the room right of the bar: the plot panel, or 0.
    var onBarLayout: ((CGFloat) -> Void)?
    /// The quick switcher floats over everything right of the sidebar: the well and the plot panel.
    /// Inside the pane area it was clipped to the well, and the panel took the room of its preview.
    var switcher: NSView?
    /// The height of the bar at the bottom of the window, right of the sidebar.
    var barHeight: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        isVertical = true
        dividerStyle = .thin
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var dividerColor: NSColor { LoamTheme.rule }

    /// The frame under the sidebar follows the sidebar's width in a translucent window.
    override func layout() {
        super.layout()
        if ChromePalette.shared.isTranslucent { needsDisplay = true }
        if let container = bar?.superview {
            bar?.frame = convert(barRect, to: container)
            // The actions menu lines up with the Actions button, at the right end of the bar.
            onBarLayout?(bounds.maxX - barRect.maxX)
            overlay?.frame = convert(bounds, to: container)
            switcher?.frame = convert(switcherRect, to: container)
        }
    }

    /// Everything right of the sidebar. The regions there cover it, so only the gaps show it.
    private var chromeRect: CGRect {
        let sidebar = arrangedSubviews.first.flatMap { isSubviewCollapsed($0) || $0.isHidden ? nil : $0 }
        let minX = sidebar.map { $0.frame.maxX } ?? bounds.minX
        return CGRect(x: minX, y: bounds.minY, width: bounds.maxX - minX, height: bounds.height)
    }

    /// The room of the quick switcher: right of the sidebar, above the action bar.
    private var switcherRect: CGRect {
        var rect = chromeRect
        rect.size.height -= barRect.height
        if !isFlipped { rect.origin.y += barRect.height }
        return rect
    }

    /// The strip of the action bar: the bottom of the column, under the well. It ends where the
    /// well ends, so the plot panel keeps the full height of the window.
    var barRect: CGRect {
        guard bar != nil, barHeight > 0, arrangedSubviews.count > 1 else { return .zero }
        let column = arrangedSubviews[1].frame
        let y = isFlipped ? bounds.maxY - barHeight : bounds.minY
        return CGRect(x: column.minX, y: y, width: column.width, height: barHeight)
    }

    /// The frame behind the glass sidebar is `frame` (tickets 68 and 70): `bedrock` in Night, so the
    /// glass reads lighter than the frame, and `horizon-o` in Day, so the edge of the glass shows.
    /// In a translucent window the frame sits under the sidebar only. Its alpha with the glass over
    /// it matches the window alpha (`ChromePalette.frameUnderGlassAlpha`), so the sidebar is as
    /// see-through as the panes. The other regions paint their own ground, and a frame under them
    /// would stack its alpha on theirs.
    override func draw(_ dirtyRect: NSRect) {
        if !ChromePalette.shared.isTranslucent {
            LoamTheme.frame.setFill()
            dirtyRect.fill()
            // Right of the sidebar, the frame is the chrome ground: the gaps between the regions.
            LoamTheme.chrome.setFill()
            chromeRect.intersection(dirtyRect).fill()
        } else {
            if let sidebar = arrangedSubviews.first, !isSubviewCollapsed(sidebar) {
                let alpha = ChromePalette.frameUnderGlassAlpha(windowOpacity: ChromePalette.shared.windowOpacity)
                NSColor(name: nil) { appearance in
                    var color = LoamTheme.frame
                    appearance.performAsCurrentDrawingAppearance { color = LoamTheme.frame.usingColorSpace(.sRGB) ?? color }
                    return color.withAlphaComponent(alpha)
                }.setFill()
                sidebar.frame.intersection(dirtyRect).fill(using: .copy)
            }
            // The dividers draw nothing, so the frame showed through them. Fill the gaps between the
            // regions at the window alpha, or each one shows the desktop as a light line.
            LoamTheme.ground(LoamTheme.chrome).setFill()
            let shown = arrangedSubviews.filter { !$0.isHidden && !isSubviewCollapsed($0) && $0.frame.width > 0 }
            for (left, right) in zip(shown, shown.dropFirst()) where right.frame.minX > left.frame.maxX {
                CGRect(x: left.frame.maxX, y: bounds.minY, width: right.frame.minX - left.frame.maxX, height: bounds.height)
                    .intersection(dirtyRect).fill(using: .copy)
            }
        }
        super.draw(dirtyRect)
    }
}
