import AppKit
import LoamKit
import LoamTerminal

/// The scripted driver: a test mode of the app. Start the app with
/// `LOAM_DRIVER=<scenario>` and `LOAM_DRIVER_OUT=<folder>`. The driver opens its
/// own window, runs the scenario, writes `driver.log` and screenshots to the
/// folder, and quits. The last log line is `PASS <scenario>` or `FAIL <scenario>: <why>`.
///
/// The run stays in the background: the app does not come to the front and does not take
/// your keyboard. Set `LOAM_DRIVER_FOREGROUND=1` to watch it in front.
///
/// Exit codes: 0 pass, 1 fail, 3 the main thread hung for 10 s (a sample is in
/// the folder), 4 the scenario ran past its time limit.
public enum Driver {
    public static var scenarioName: String? {
        ProcessInfo.processInfo.environment["LOAM_DRIVER"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// True when the run brings the app to the front, as a launch does.
    static var foreground: Bool { ProcessInfo.processInfo.environment["LOAM_DRIVER_FOREGROUND"] == "1" }

    /// Builds the real app window for the scenarios that drive the panel. Loam
    /// provides it, because the views live in the Loam target. With a runtime,
    /// the panes are terminal surfaces with pane sockets. Without one, they are placeholders.
    public typealias HostFactory = @MainActor (LoamClient, AppStateFile, TerminalRuntime?) -> AppHost

    @MainActor
    public static func run(_ name: String, host: HostFactory? = nil) -> Never {
        let app = NSApplication.shared
        let delegate = DriverApp(scenario: name, hostFactory: host)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        exit(0)
    }
}

/// The real app window and model, for a scenario that drives the panel.
public struct AppHost {
    public let window: NSWindow
    public let model: AppModel
    /// Keeps the window controller alive.
    public let owner: AnyObject
    /// The content view of a pane: a `TerminalSurfaceView` when the host has terminals.
    public let paneView: @MainActor (PaneID) -> NSView?
    /// The app's quit, without the process exit: the question when a session is mid-turn, the
    /// last layout write, and the safe close of every pane. It calls back with false on Cancel.
    public let quit: @MainActor (@escaping @MainActor (Bool) -> Void) -> Void

    public init(window: NSWindow, model: AppModel, owner: AnyObject,
                paneView: @escaping @MainActor (PaneID) -> NSView? = { _ in nil },
                quit: @escaping @MainActor (@escaping @MainActor (Bool) -> Void) -> Void = { $0(true) }) {
        self.window = window
        self.model = model
        self.owner = owner
        self.paneView = paneView
        self.quit = quit
    }
}

struct DriverFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Timestamped lines to `driver.log` in the out folder, and to stderr.
enum Log {
    private static let start = Date()
    nonisolated(unsafe) private static var file: FileHandle?
    private static let lock = NSLock()

    static func open(_ path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        file = FileHandle(forWritingAtPath: path)
    }

    static func line(_ message: String) {
        let text = String(format: "[%8.3f] ", Date().timeIntervalSince(start)) + message + "\n"
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(text.utf8))
        file?.write(Data(text.utf8))
    }
}

/// Catches a main-thread hang, such as one inside `ghostty_surface_free`. The
/// main thread beats every 100 ms. After 10 s with no beat, the watchdog
/// samples the process to the out folder and exits with code 3.
final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBeat = ProcessInfo.processInfo.systemUptime
    private let timer = DispatchSource.makeTimerSource(queue: .global())
    private let outFolder: String
    let limit: TimeInterval = 10

    init(outFolder: String) {
        self.outFolder = outFolder
        timer.schedule(deadline: .now() + 0.25, repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
    }

    func beat() {
        lock.lock()
        lastBeat = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    private func check() {
        lock.lock()
        let silent = ProcessInfo.processInfo.systemUptime - lastBeat
        lock.unlock()
        guard silent > limit else { return }
        Log.line("HANG: the main thread did not run for \(Int(limit)) s")
        let path = "\(outFolder)/sample-\(getpid()).txt"
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = ["\(getpid())", "3", "-file", path]
        try? sample.run()
        sample.waitUntilExit()
        Log.line("HANG: sample in \(path)")
        _exit(3)
    }
}

@MainActor
final class DriverApp: NSObject, NSApplicationDelegate {
    let scenario: String
    let outFolder: String
    /// The driver's Ghostty config file. The runtime watches it.
    var configPath: String { "\(outFolder)/ghostty.config" }
    /// The config of every run. No padding: cell (0, 0) is at the top left of the view.
    static let baseConfig = """
        font-size = 13
        window-padding-x = 0
        window-padding-y = 0
        window-padding-balance = false
        cursor-style-blink = false

        """
    private(set) var runtime: TerminalRuntime!
    private(set) var window: NSWindow!
    private var watchdog: Watchdog?
    private(set) var panes: [TerminalSurfaceView] = []
    private var shotNumber = 0
    private let hostFactory: Driver.HostFactory?
    private(set) var host: AppHost?

    init(scenario: String, hostFactory: Driver.HostFactory?) {
        self.scenario = scenario
        self.hostFactory = hostFactory
        let environment = ProcessInfo.processInfo.environment
        outFolder = environment["LOAM_DRIVER_OUT"] ?? NSTemporaryDirectory() + "loam-driver-\(getpid())"
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: outFolder, withIntermediateDirectories: true)
        Log.open("\(outFolder)/driver.log")
        Log.line("scenario \(scenario), pid \(getpid())")

        let watchdog = Watchdog(outFolder: outFolder)
        self.watchdog = watchdog
        let beat = Timer(timeInterval: 0.1, repeats: true) { _ in watchdog.beat() }
        RunLoop.main.add(beat, forMode: .common)

        // A fixed config in the out folder, so the run never reads or changes your Ghostty config.
        try? Self.baseConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
        // The `theme`, `pane-resources`, `frame-shot`, `panel-shot`, and `readme-shots` scenarios also load Loam's own theme defaults, as the app does.
        let defaults = ["theme", "pane-resources", "frame-shot", "panel-shot", "sidebar-shot", "readme-shots", "actions"].contains(scenario) ? (TerminalThemeDefaults.writeDefaultsFile(cacheFolder: URL(fileURLWithPath: outFolder)).map { [$0] } ?? []) : []
        runtime = TerminalRuntime(config: TerminalRuntime.ConfigSource(defaults: defaults, user: [configPath], watch: true))
        for diagnostic in runtime.configDiagnostics { Log.line("config: \(diagnostic)") }
        // A private pasteboard, so the run never touches your clipboard.
        runtime.pasteboard = NSPasteboard(name: .init("dev.loam.driver.\(getpid())"))
        runtime.selectionPasteboard = NSPasteboard(name: .init("dev.loam.driver.selection.\(getpid())"))
        // In the background, the window is behind your windows and never key. The panes still draw and take focus.
        runtime.assumesKeyAndVisible = !Driver.foreground

        window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1000, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Loam driver: \(scenario)"
        window.contentView = NSView()
        show(window)

        guard let run = Scenarios.all.first(where: { $0.name == scenario }) else {
            finish(.failure(DriverFailure("unknown scenario. Known: \(Scenarios.all.map(\.name).joined(separator: ", "))")))
            return
        }
        let limit = Timer(timeInterval: run.limit, repeats: false) { _ in
            Log.line("FAIL \(self.scenario): the scenario ran past \(Int(run.limit)) s")
            _exit(4)
        }
        RunLoop.main.add(limit, forMode: .common)
        Task { @MainActor in
            do {
                try await run.body(self)
                finish(.success(()))
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        for pane in panes { dump(pane, "at end") }
        let counts = runtime?.actionCounts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" } ?? []
        Log.line("action counts by tag: \(counts.joined(separator: " "))")
        runtime?.pasteboard.releaseGlobally()
        runtime?.selectionPasteboard.releaseGlobally()
        switch result {
        case .success:
            Log.line("PASS \(scenario)")
            exit(0)
        case .failure(let error):
            screenshot("fail")
            Log.line("FAIL \(scenario): \(error)")
            exit(1)
        }
    }

    /// Replaces the driver window with the real app window, and loads the plots.
    /// `client` and `state` point at a temp store. With `terminals`, the panes are
    /// terminal surfaces on the driver's runtime. Without it, they are placeholders.
    func launchApp(client: LoamClient, state: AppStateFile, terminals: Bool = false) async throws -> AppHost {
        guard let hostFactory else { throw DriverFailure("this build has no app host") }
        let host = hostFactory(client, state, terminals ? runtime : nil)
        self.host = host
        AccessibilityProbe.shared.start()
        window.orderOut(nil)
        window = host.window
        window.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 700), display: true)
        show(window)
        await host.model.launch()
        return host
    }

    /// In front and active with `LOAM_DRIVER_FOREGROUND=1`. Else behind your windows, with the app inactive.
    private func show(_ window: NSWindow) {
        if Driver.foreground {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            window.orderBack(nil)
        }
    }

    // MARK: Panes

    /// Adds a pane and lays out every pane side by side.
    func addPane(_ name: String, command: String?, env: [String: String] = [:]) throws -> TerminalSurfaceView {
        let spec = PaneSpec(kind: .shell, plot: "driver", folder: outFolder, command: command,
                            env: env.merging(["LOAM_DRIVER_PANE": name]) { a, _ in a }, title: name)
        let pane = try TerminalSurfaceView(runtime: runtime, spec: spec)
        pane.identifier = NSUserInterfaceItemIdentifier(name)
        window.contentView!.addSubview(pane)
        panes.append(pane)
        layoutPanes()
        window.makeFirstResponder(pane)
        Log.line("pane \(name) started: \(command ?? "login shell")")
        return pane
    }

    func layoutPanes() {
        let bounds = window.contentView!.bounds
        let width = (bounds.width - CGFloat(panes.count - 1)) / CGFloat(max(panes.count, 1))
        for (i, pane) in panes.enumerated() {
            pane.frame = NSRect(x: CGFloat(i) * (width + 1), y: 0, width: width, height: bounds.height)
        }
    }

    /// Closes the pane with the safe order and waits for the free.
    func close(_ pane: TerminalSurfaceView) async -> TerminalSurfaceView.CloseResult {
        let name = pane.identifier?.rawValue ?? "?"
        let result = await withCheckedContinuation { continuation in
            pane.close { continuation.resume(returning: $0) }
        }
        pane.removeFromSuperview()
        panes.removeAll { $0 === pane }
        layoutPanes()
        Log.line(String(format: "pane %@ closed: exit wait %.3f s, free %.3f s, signals [%@], forced %@",
                        name, result.waited, result.free, result.signals.joined(separator: ", "),
                        result.forced ? "yes" : "no"))
        return result
    }

    // MARK: Output

    func dump(_ pane: TerminalSurfaceView, _ label: String) {
        let lines = pane.screenText().split(separator: "\n", omittingEmptySubsequences: false)
        let body = lines.suffix(30).map { "    | \($0)" }.joined(separator: "\n")
        Log.line("SCREEN \(pane.identifier?.rawValue ?? "?") \(label):\n\(body)")
    }

    /// A screenshot of the driver's window, or of `other`, such as the settings window.
    func screenshot(_ name: String, of other: NSWindow? = nil) {
        shotNumber += 1
        let path = String(format: "%@/%02d-%@.png", outFolder, shotNumber, name)
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", "\((other ?? window).windowNumber)", path]
        try? shot.run()
        shot.waitUntilExit()
        Log.line("screenshot \(path)\(FileManager.default.fileExists(atPath: path) ? "" : " (not written)")")
    }
}
