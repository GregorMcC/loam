import Foundation

/// The app's only path to the core. It runs the `loam` binary, reads stdout and the exit code,
/// and never parses message text. Every call is async and runs the process off the main actor.
public struct LoamClient: Sendable {
    public enum TextField: String, Sendable {
        case name, what, why
        case whereItStands = "where-it-stands"
    }

    /// The binary that `loam_path` in the settings file gives, or the one that Automatic finds.
    public static var defaultBinary: URL {
        URL(fileURLWithPath: LoamBinary.resolve(setting: SettingsFile().read().settings.loamPath).path)
    }

    public let binary: URL
    /// The contract version this client accepts. Tests change it.
    public let expectedContract: Int
    /// Extra environment for the process, such as `LOAM_HOME`.
    public let environment: [String: String]

    public init(
        binary: URL = LoamClient.defaultBinary,
        expectedContract: Int = LoamKit.contractVersion,
        environment: [String: String] = [:]
    ) {
        self.binary = binary
        self.expectedContract = expectedContract
        self.environment = environment
    }

    // MARK: Launch checks

    public func version() async throws -> VersionInfo {
        try await read(["version"])
    }

    /// Throws `LoamError.contractVersionMismatch` when the core reads another contract version.
    @discardableResult
    public func checkContract() async throws -> VersionInfo {
        let info = try await version()
        guard info.contractVersion == expectedContract else {
            throw LoamError.contractVersionMismatch(core: info.contractVersion, app: expectedContract)
        }
        return info
    }

    public func setupCheck() async throws -> SetupCheck {
        try await read(["setup", "--check"])
    }

    // MARK: Reads

    public func list() async throws -> [PlotSummary] {
        try await read(["list"])
    }

    /// Only the archived plots, in the stored order.
    public func listArchived() async throws -> [PlotSummary] {
        try await read(["list", "--archived"])
    }

    public func show(plot: String) async throws -> Plot {
        try await read(["show", plot])
    }

    /// The change log, oldest first. Without `plot` it covers every plot.
    public func changes(plot: String? = nil, since: Int? = nil) async throws -> [Change] {
        var args = ["changes"]
        if let plot { args.append(plot) }
        if let since { args += ["--since", String(since)] }
        let response: ChangesResponse = try await read(args)
        return response.changes
    }

    public func sessions(plot: String? = nil) async throws -> [SessionRecord] {
        try await read(["sessions"] + (plot.map { [$0] } ?? []))
    }

    public func export(includeChanges: Bool = false) async throws -> ExportResponse {
        try await read(["export"] + (includeChanges ? ["--changes"] : []))
    }

    /// The worktrees of one plot, or of every plot, with their checks. Oldest first.
    public func worktrees(plot: String? = nil) async throws -> [WorktreeStatus] {
        try await read(["worktree", "list"] + (plot.map { [$0] } ?? []))
    }

    // MARK: Writes (all with `--actor app`)

    public func new(name: String) async throws -> Plot {
        try await write(["new", name])
    }

    /// Sets a text field. The text goes on stdin, so it can hold any characters.
    public func set(plot: String, field: TextField, text: String, expect: [String: Int] = [:]) async throws -> Plot {
        try await write(["set", plot, field.rawValue, "-"] + expectArgs(expect), stdin: text)
    }

    /// An empty label leaves it out, so the core takes the label from the target.
    public func linkAdd(plot: String, label: String, target: String, note: String? = nil, expect: [String: Int] = [:]) async throws -> WriteResult {
        try await write(["link", "add", plot] + (label.isEmpty ? [] : [label]) + [target] + noteArg(note) + expectArgs(expect))
    }

    public func linkEdit(plot: String, link: String, label: String? = nil, target: String? = nil, note: String? = nil, expect: [String: Int] = [:]) async throws -> WriteResult {
        var args = ["link", "edit", plot, link]
        if let label { args += ["--label", label] }
        if let target { args += ["--target", target] }
        return try await write(args + noteArg(note) + expectArgs(expect))
    }

    public func linkRemove(plot: String, link: String, expect: [String: Int] = [:]) async throws -> WriteResult {
        try await write(["link", "rm", plot, link] + expectArgs(expect))
    }

    public func repoAdd(plot: String, path: String, note: String? = nil, expect: [String: Int] = [:]) async throws -> WriteResult {
        try await write(["repo", "add", plot, path] + noteArg(note) + expectArgs(expect))
    }

    public func repoEdit(plot: String, repo: String, note: String? = nil, expect: [String: Int] = [:]) async throws -> WriteResult {
        try await write(["repo", "edit", plot, repo] + noteArg(note) + expectArgs(expect))
    }

    public func repoMain(plot: String, repo: String, expect: [String: Int] = [:]) async throws -> WriteResult {
        try await write(["repo", "main", plot, repo] + expectArgs(expect))
    }

    /// Removing the main repo needs `newMain`, because `--json` cannot ask.
    public func repoRemove(plot: String, repo: String, newMain: String? = nil, expect: [String: Int] = [:]) async throws -> WriteResult {
        try await write(["repo", "rm", plot, repo] + (newMain.map { ["--main", $0] } ?? []) + expectArgs(expect))
    }

    /// `loam worktree new`. `repo` is a repo ID or a path.
    public func worktreeNew(plot: String, repo: String, name: String, base: String? = nil) async throws -> WorktreeNewResult {
        try await write(["worktree", "new", plot, repo, name] + (base.map { ["--base", $0] } ?? []))
    }

    /// `loam worktree rm`. `openPanes` are the folders of the panes that are open or saved, so the core
    /// can refuse. `force` skips the checks for changes and unpushed commits, never the pane check.
    public func worktreeRemove(plot: String, worktree: String, force: Bool = false, openPanes: [String] = []) async throws -> WorktreeRmResult {
        try await write(["worktree", "rm", plot, worktree] + (force ? ["--force"] : [])
            + openPanes.flatMap { ["--open-pane", $0] })
    }

    /// `loam archive`. Does nothing when the plot is archived already. It ends no session: the app does that.
    public func archive(plot: String) async throws -> Plot {
        try await write(["archive", plot])
    }

    /// `loam unarchive`. The plot goes back to its old place in the order.
    public func unarchive(plot: String) async throws -> Plot {
        try await write(["unarchive", plot])
    }

    /// `loam delete`. Works only on an archived plot with no worktrees. There is no undo.
    public func delete(plot: String) async throws -> DeleteResult {
        try await write(["delete", plot])
    }

    /// `loam open`. `link` is a link ID or an exact label. A missing local path throws `.linkPathMissing`.
    public func open(plot: String, link: String) async throws -> OpenResult {
        try await write(["open", plot, link])
    }

    /// Moves a plot in the plot order. `position` starts at 1.
    public func move(plot: String, position: Int) async throws -> MoveResult {
        try await write(["move", plot, String(position)])
    }

    /// Throws `LoamError.undoClash` when a later change touched the same items.
    /// Call again with `overwrite: true` to write anyway.
    public func undo(changeID: Int, overwrite: Bool = false) async throws -> UndoResult {
        try await write(["undo", String(changeID)] + (overwrite ? ["--overwrite"] : []))
    }

    // MARK: Plumbing

    private func expectArgs(_ expect: [String: Int]) -> [String] {
        expect.sorted { $0.key < $1.key }.flatMap { ["--expect", "\($0.key)=\($0.value)"] }
    }

    private func noteArg(_ note: String?) -> [String] {
        note.map { ["--note", $0] } ?? []
    }

    private func read<T: Decodable>(_ args: [String]) async throws -> T {
        try decode(await run(args + ["--json"], stdin: nil))
    }

    private func write<T: Decodable>(_ args: [String], stdin: String? = nil) async throws -> T {
        try decode(await run(args + ["--json", "--actor", "app"], stdin: stdin))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LoamError.undecodable(String(describing: error))
        }
    }

    /// The environment of a `loam` process: the app's environment without the Ghostty resources
    /// folder (ticket 59), then `extra`. The app sets that variable for libghostty only.
    static func childEnvironment(inherited: [String: String], extra: [String: String]) -> [String: String] {
        var result = inherited
        result["GHOSTTY_RESOURCES_DIR"] = nil
        return result.merging(extra) { $1 }
    }

    /// Runs the binary on a background queue. Returns stdout on exit 0, and throws otherwise.
    private func run(_ args: [String], stdin: String?) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw LoamError.binaryMissing(path: binary.path)
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = Self.childEnvironment(inherited: ProcessInfo.processInfo.environment, extra: environment)
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = inPipe
        let input = Data((stdin ?? "").utf8)
        let box = ProcessBox(process: process, out: out, err: err, inPipe: inPipe)

        try Task.checkCancellation()
        let result: (status: Int32, signaled: Bool, stdout: Data, stderr: Data) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                box.start(input: input) { result in
                    cont.resume(with: result.mapError {
                        $0 is CancellationError ? $0 : LoamError.launchFailed($0.localizedDescription)
                    })
                }
            }
        } onCancel: {
            box.terminate()
        }
        if Task.isCancelled { throw CancellationError() }
        if result.signaled {
            // A signal number is not a contract exit code.
            throw LoamError.failed(message: "The loam command stopped with signal \(result.status).")
        }
        if result.status == 0 { return result.stdout }

        // The exit code decides the case. The JSON error supplies the message and details.
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: result.stdout)
        let message = envelope?.error.message
            ?? String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw LoamError.from(exitCode: result.status, message: message, details: envelope?.error.details?.data)
    }
}

/// Runs one process to the end. Reads both pipes at once, so a full pipe cannot block the child.
/// No thread waits: handlers collect the output and the exit. A runner that blocked dispatch
/// threads deadlocked when many calls ran at once, because the reads it waited on had no thread.
private final class ProcessBox: @unchecked Sendable {
    typealias Output = (status: Int32, signaled: Bool, stdout: Data, stderr: Data)

    let process: Process
    let out: Pipe, err: Pipe, inPipe: Pipe
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data()
    private var cancelled = false

    init(process: Process, out: Pipe, err: Pipe, inPipe: Pipe) {
        self.process = process; self.out = out; self.err = err; self.inPipe = inPipe
    }

    func terminate() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }

    /// Calls `completion` once, after the process exits and both pipes reach end of file.
    func start(input: Data, completion: @escaping @Sendable (Result<Output, Error>) -> Void) {
        signal(SIGPIPE, SIG_IGN)  // A child that exits early must not kill the app on the stdin write.
        let group = DispatchGroup()
        group.enter(); group.enter(); group.enter()  // stdout, stderr, exit
        collect(out.fileHandleForReading, group: group) { $0.stdout.append($1) }
        collect(err.fileHandleForReading, group: group) { $0.stderr.append($1) }
        process.terminationHandler = { _ in group.leave() }

        lock.lock()
        let launch: Result<Void, Error> = cancelled ? .failure(CancellationError()) : Result { try process.run() }
        lock.unlock()
        if case .failure(let error) = launch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            completion(.failure(error))
            return
        }

        let writer = inPipe.fileHandleForWriting
        DispatchQueue.global().async {
            try? writer.write(contentsOf: input)
            try? writer.close()
        }
        group.notify(queue: .global()) { [self] in
            lock.lock(); defer { lock.unlock() }
            completion(.success((process.terminationStatus, process.terminationReason == .uncaughtSignal, stdout, stderr)))
        }
    }

    private func collect(_ handle: FileHandle, group: DispatchGroup, append: @escaping @Sendable (ProcessBox, Data) -> Void) {
        handle.readabilityHandler = { [self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                group.leave()
            } else {
                lock.lock(); append(self, data); lock.unlock()
            }
        }
    }
}
