import Foundation

/// Watches the Ghostty config files with FSEvents and calls `onChange` once per burst of writes.
/// An editor that saves through a temporary file writes several events. The debounce makes them one reload.
@MainActor
public final class ConfigWatch {
    /// Makes the event stream for a list of files.
    public typealias Triggers = @Sendable (_ files: [String]) -> AsyncStream<Void>

    public var onChange: (() -> Void)?
    /// The files that the watch covers now.
    public private(set) var files: [String] = []

    private let makeTriggers: Triggers
    private let debounce: Duration
    private var task: Task<Void, Never>?
    private var pending: Task<Void, Never>?

    public init(debounce: Duration = .milliseconds(150), makeTriggers: @escaping Triggers = ConfigWatch.fileEvents) {
        self.debounce = debounce
        self.makeTriggers = makeTriggers
    }

    /// Watches the files by `GhosttyConfigFiles.watchPlan`. Only an event for one of the files,
    /// or for a theme, counts. When a missing config folder appears, the watch moves to it and
    /// sends one event, so a file made at the same time loads too.
    public static let fileEvents: Triggers = { files in
        AsyncStream { continuation in
            let watcher = ConfigFolderWatcher(files: files) { continuation.yield() }
            continuation.onTermination = { _ in watcher.stop() }
        }
    }

    /// Starts the watch, or moves it to a new list of files. The same list keeps the running watch.
    public func watch(_ files: [String]) {
        guard files != self.files || task == nil else { return }
        stop()
        self.files = files
        let triggers = makeTriggers(files)
        task = Task { [weak self] in
            for await _ in triggers {
                guard let self, !Task.isCancelled else { return }
                self.trigger()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        pending?.cancel()
        pending = nil
    }

    private func trigger() {
        pending?.cancel()
        let debounce = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.onChange?()
        }
    }
}

/// The file system part of `ConfigWatch.fileEvents`: FSEvents on the plan's folders, and a
/// kqueue watch with no subfolders on each of its parents. All state is on `queue`.
///
/// The plan and the event filter are made again after each config event, after a change in a
/// parent folder, and when a watched folder itself changes (FSEvents reports it when the folder
/// goes). So a config folder that appears or goes, or a config file that becomes a link, moves
/// the watch.
final class ConfigFolderWatcher: @unchecked Sendable {
    private let files: [String]
    private let onEvent: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.loam.config-watch")
    private var plan = GhosttyConfigFiles.WatchPlan()
    private var filter = ConfigEventFilter(files: [])
    private var folderTask: Task<Void, Never>?
    private var parentSources: [DispatchSourceFileSystemObject] = []
    private var stopped = false

    init(files: [String], onEvent: @escaping @Sendable () -> Void) {
        self.files = files
        self.onEvent = onEvent
        queue.async { self.start(GhosttyConfigFiles.watchPlan(for: files), ConfigEventFilter(files: files)) }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.tearDown()
        }
    }

    private func start(_ plan: GhosttyConfigFiles.WatchPlan, _ filter: ConfigEventFilter) {
        guard !stopped else { return }
        self.plan = plan
        self.filter = filter
        let roots = Set(plan.folders.flatMap(ConfigEventFilter.names(of:)))
        let events = DirectoryWatcher.events(at: plan.folders.map { URL(fileURLWithPath: $0) }, latency: 0.05) {
            filter.accepts($0) || roots.contains($0)
        }
        let onEvent = onEvent
        folderTask = Task { [weak self] in
            for await _ in events {
                onEvent()
                self?.queue.async { self?.replan() }
            }
        }
        for parent in plan.parents {
            let fd = Darwin.open(parent, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
            source.setEventHandler { [weak self] in self?.replan() }
            source.setCancelHandler { Darwin.close(fd) }
            parentSources.append(source)
            source.resume()
        }
    }

    private func tearDown() {
        folderTask?.cancel()
        folderTask = nil
        for source in parentSources { source.cancel() }
        parentSources = []
    }

    /// Makes the plan and the filter again. When either changed, the watch moves and the config
    /// loads again, so a file made at the same moment is not missed.
    private func replan() {
        guard !stopped else { return }
        let nextPlan = GhosttyConfigFiles.watchPlan(for: files)
        let nextFilter = ConfigEventFilter(files: files)
        guard nextPlan != plan || nextFilter != filter else { return }
        tearDown()
        start(nextPlan, nextFilter)
        onEvent()
    }
}
