import AppKit
import LoamKit

#if canImport(GhosttyKit)
import LoamDriver
import LoamTerminal
#endif

/// One window. Closing the last window quits the app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private let model = AppModel()
    #if canImport(GhosttyKit)
    private var runtime: TerminalRuntime?
    private var terminalFactory: TerminalPaneViewFactory?
    #endif
    /// Quit is in progress: the question shows or the panes close.
    private var quitting = false
    /// The panes are closed, so the next terminate goes ahead.
    private var readyToQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let stateFile = AppStateFile()
        model.startRestore(from: stateFile)
        model.useTimes = model.stateWriter.map(UseTimes.init(writer:))
        let controller = MainWindowController(model: model, factory: makeFactory())
        windowController = controller
        // The banner and the Dock badge for panes that need you (spec 8.4). A click on a banner
        // brings Loam to the front and focuses the pane.
        let notifier = SystemAttentionNotifier()
        notifier.onOpen = { [weak model] pane in
            NSApp.activate()
            model?.goToPane(pane)
        }
        model.notifier = notifier
        let menu = makeMainMenu(target: controller)
        NSApp.mainMenu = menu
        controller.showWindow(nil)
        NSApp.activate()
        #if canImport(GhosttyKit)
        if let runtime, let window = controller.window { wire(runtime, controller: controller, window: window, menu: menu) }
        #endif
        Task { await model.launch() }
    }

    private func makeFactory() -> PaneViewFactory {
        #if canImport(GhosttyKit)
        // Loam's themes load first, so a `theme` line in your Ghostty config still wins (ticket 55).
        let defaults = TerminalThemeDefaults.writeDefaultsFile().map { [$0] } ?? []
        let runtime = TerminalRuntime(config: TerminalRuntime.ConfigSource(defaults: defaults))
        self.runtime = runtime
        let factory = TerminalPaneViewFactory(runtime: runtime)
        factory.connect(to: model)
        terminalFactory = factory
        return factory
        #else
        return PlaceholderPaneViewFactory()
        #endif
    }

    #if canImport(GhosttyKit)
    /// Connects the Ghostty config (spec 8.3) to the window: actions and fixed keys run window
    /// commands, the menu shows your config's keys, the window takes the appearance options,
    /// and a load with errors shows them.
    private func wire(_ runtime: TerminalRuntime, controller: MainWindowController, window: NSWindow, menu: NSMenu) {
        runtime.commandHandler = { [weak controller] in controller?.perform($0) ?? false }
        controller.onConfigCommand = { [weak runtime] command in
            if command == .openConfig { runtime?.openConfigFile() } else { runtime?.reloadConfig() }
        }
        followTerminal(runtime, controller: controller, window: window)
        connectTerminalConfig(runtime, to: model.terminalConfig)
        runtime.onConfigLoad = { [weak runtime, weak controller, weak menu, weak model] load in
            guard let runtime else { return }
            if let menu { applyGhosttyShortcuts(to: menu, chord: runtime.chord(forGhosttyAction:)) }
            model?.terminalConfig.update(from: load, canOpen: runtime.canOpenConfig)
            controller?.showConfigErrors(for: load.outcome, canOpenConfig: runtime.canOpenConfig)
        }
        applyGhosttyShortcuts(to: menu, chord: runtime.chord(forGhosttyAction:))
        controller.showConfigErrors(for: runtime.lastConfigLoad.outcome, canOpenConfig: runtime.canOpenConfig)
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quit (spec 8.5): ask only when a session is mid-turn, then close every pane with the safe order.
    /// With no question, quit waits for the closes (`terminateLater`), so a logout is not stopped.
    /// With a question, this terminate stops, and a yes starts a new one once the panes are closed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = windowController, !readyToQuit else { return .terminateNow }
        guard !quitting else { return .terminateCancel }
        quitting = true
        guard controller.quitPrompt != nil else {
            controller.closeEveryPane { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        controller.requestQuit { [weak self] quit in
            guard let self else { return }
            quitting = false
            guard quit else { return }
            readyToQuit = true
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if canImport(GhosttyKit)
        terminalFactory?.closeAllSockets()
        #endif
    }
}

#if canImport(GhosttyKit)
/// The settings window's Terminal tab: the actions, and the last load.
@MainActor
func connectTerminalConfig(_ runtime: TerminalRuntime, to model: TerminalConfigModel) {
    model.open = { [weak runtime] in runtime?.openConfigFile() }
    model.reload = { [weak runtime] in runtime?.reloadConfig() }
    model.update(from: runtime.lastConfigLoad, canOpen: runtime.canOpenConfig)
}

extension TerminalConfigModel {
    func update(from load: ConfigLoad, canOpen: Bool) {
        files = load.files
        errors = load.outcome.errors
        self.canOpen = canOpen
    }
}

/// The window follows the Ghostty config (spec 8.3): opacity, blur, and appearance. The chrome
/// surfaces follow the terminal background (ticket 68). It runs now and on each config change,
/// which includes a switch between Night and Day. The palette changes first, so the appearance
/// change that follows draws the new surfaces.
@MainActor
func followTerminal(_ runtime: TerminalRuntime, controller: MainWindowController, window: NSWindow) {
    let apply = { [weak runtime, weak controller, weak window] in
        guard let runtime, let window else { return }
        let appearance = runtime.windowAppearance
        controller?.terminalBackgroundChanged(appearance.terminalBackground, opacity: appearance.opacity)
        runtime.applyWindowAppearance(to: window)
    }
    runtime.onConfigChange = apply
    // The window is visible now, so the blur takes effect.
    apply()
}
#endif

// Finder and the Dock give the app the launchd PATH. Take the PATH of your login shell, so panes and
// `loam` calls find what `.zshrc` adds (ticket 66). This is before libghostty starts, because libghostty
// keeps the environment. It waits 5 s at most. The driver skips it, so a scenario does not depend on
// your shell.
if (ProcessInfo.processInfo.environment["LOAM_DRIVER"] ?? "").isEmpty {
    ShellEnvironment.applyToProcessBlocking()
}

#if canImport(GhosttyKit)
// libghostty starts before any window, after the leaked variables are gone (spec 8.2).
guard TerminalRuntime.bootstrap(resources: TerminalRuntime.resourcesFolder()) else {
    FileHandle.standardError.write(Data("libghostty failed to start.\n".utf8))
    exit(1)
}
// Test mode: LOAM_DRIVER=<scenario> runs one driver scenario, then quits.
if let scenario = Driver.scenarioName {
    // The panel scenarios drive the real window with placeholder panes. The pane scenarios pass
    // the driver's runtime and get terminal panes.
    Driver.run(scenario) { client, state, runtime in
        let model = AppModel(client: client, stateFile: state)
        model.startRestore(from: state)
        model.useTimes = model.stateWriter.map(UseTimes.init(writer:))
        var factory: PaneViewFactory = PlaceholderPaneViewFactory()
        if let runtime {
            let terminals = TerminalPaneViewFactory(runtime: runtime)
            terminals.connect(to: model)
            factory = terminals
        }
        let controller = MainWindowController(model: model, factory: factory)
        NSApp.mainMenu = makeMainMenu(target: controller)
        controller.showWindow(nil)
        runtime?.commandHandler = { [weak controller] in controller?.perform($0) ?? false }
        if let runtime, let window = controller.window { followTerminal(runtime, controller: controller, window: window) }
        if let runtime { connectTerminalConfig(runtime, to: model.terminalConfig) }
        return AppHost(window: controller.window!, model: model, owner: controller,
                       paneView: { [weak controller] in controller?.paneContent($0) },
                       quit: { [weak controller] done in controller?.requestQuit(done) ?? done(true) })
    }
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
