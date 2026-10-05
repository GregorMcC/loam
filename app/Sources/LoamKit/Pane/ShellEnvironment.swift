import Foundation

/// The PATH of your login shell, for an app that Finder or the Dock started (ticket 66).
///
/// Such an app has the launchd PATH. A pane runs `$SHELL -lc`, which reads `.zprofile` but not
/// `.zshrc`, so the folders that `.zshrc` adds (such as `~/.local/bin`) are missing. The app asks
/// an interactive login shell for its PATH once at launch, merges it into its own PATH, and sets
/// that in its process environment. Panes and `loam` calls both start from that environment.
public enum ShellEnvironment {
    /// The unique text before and after the PATH in the shell output.
    static let startMarker = "__LOAM_PATH_START_7f3a9c__"
    static let endMarker = "__LOAM_PATH_END_7f3a9c__"

    /// How long the app waits for the shell.
    public static let defaultTimeout: TimeInterval = 5

    /// The text between the markers. Nil when a marker is missing or the text is empty.
    /// Anything else in the output, such as banners or errors from `.zshrc`, is ignored.
    static func parsePath(_ output: String) -> String? {
        guard let start = output.range(of: startMarker),
              let end = output.range(of: endMarker, range: start.upperBound..<output.endIndex)
        else { return nil }
        let path = String(output[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }

    /// The resolved entries first, then the entries of `current` that are not in them.
    /// Empty entries and duplicates are dropped.
    static func merge(resolved: String, current: String) -> String {
        var seen = Set<Substring>()
        var entries: [Substring] = []
        for entry in (resolved + ":" + current).split(separator: ":") where seen.insert(entry).inserted {
            entries.append(entry)
        }
        return entries.joined(separator: ":")
    }

    /// Runs `<shell> -l -i -c` and returns its PATH. Nil on a failure or after `timeout` seconds.
    public static func resolvedPath(shell: String, timeout: TimeInterval = defaultTimeout) async -> String? {
        await withCheckedContinuation { cont in
            ShellRun(shell: shell, timeout: timeout).start { cont.resume(returning: $0.flatMap(parsePath)) }
        }
    }

    /// Resolves the PATH and calls `setPath` with the merged value. It does not call `setPath` when
    /// the shell fails or times out, so the current PATH stays.
    public static func apply(
        shell: String = PaneCommand.userShell(),
        timeout: TimeInterval = defaultTimeout,
        currentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        setPath: (String) -> Void
    ) async {
        guard let resolved = await resolvedPath(shell: shell, timeout: timeout) else { return }
        setPath(merge(resolved: resolved, current: currentPath))
    }

    /// Resolves the PATH and sets it in the process environment. It waits at most `timeout`
    /// seconds, and it must run before libghostty starts, because libghostty keeps `environ`.
    /// Call it from the main thread before the run loop. Handlers finish the shell run on other
    /// queues, so this wait takes no dispatch thread that the run needs.
    public static func applyToProcessBlocking(shell: String = PaneCommand.userShell(), timeout: TimeInterval = defaultTimeout) {
        let done = DispatchSemaphore(value: 0)
        ShellRun(shell: shell, timeout: timeout).start { output in
            if let resolved = output.flatMap(parsePath) {
                let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
                setenv("PATH", merge(resolved: resolved, current: current), 1)
            }
            done.signal()
        }
        done.wait()
    }
}

/// One run of the shell. No thread waits: handlers collect the output, and a timer stops the shell.
/// The completion runs once, with the output, or with nil on a failure or a timeout.
private final class ShellRun: @unchecked Sendable {
    private let shell: String
    private let timeout: TimeInterval
    private let process = Process()
    private let out = Pipe(), err = Pipe()
    private let lock = NSLock()
    private var output = Data()
    private var finished = false
    private var reachedEnd = false
    private var exitStatus: Int32?
    private var completion: (@Sendable (String?) -> Void)?

    init(shell: String, timeout: TimeInterval) {
        self.shell = shell
        self.timeout = timeout
    }

    func start(completion: @escaping @Sendable (String?) -> Void) {
        self.completion = completion
        let script = "printf '%s' '\(ShellEnvironment.startMarker)'; printf '%s' \"$PATH\"; printf '%s' '\(ShellEnvironment.endMarker)'"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        // The pipes carry output that the parser ignores, so the child never blocks on a full pipe.
        out.fileHandleForReading.readabilityHandler = { [self] h in
            let data = h.availableData
            lock.lock(); defer { lock.unlock() }
            if data.isEmpty { h.readabilityHandler = nil; reachedEnd = true } else { output.append(data) }
            if data.isEmpty, exitStatus != nil { DispatchQueue.global().async { self.finishWithOutput() } }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            if h.availableData.isEmpty { h.readabilityHandler = nil }
        }
        process.terminationHandler = { [self] p in
            lock.lock()
            exitStatus = p.terminationStatus
            let ready = reachedEnd
            lock.unlock()
            if ready { finishWithOutput(); return }
            // A background job from `.zshrc` can keep the pipe open. Wait a short time for the last bytes.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { self.finishWithOutput() }
        }
        do { try process.run() } catch {
            finish(nil)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            guard !isFinished else { return }
            finish(nil)
            stop()
        }
    }

    /// Ends the run with the collected output when the shell exited with status 0.
    private func finishWithOutput() {
        lock.lock()
        let status = exitStatus
        let text = String(decoding: output, as: UTF8.self)
        lock.unlock()
        finish(status == 0 ? text : nil)
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    /// Ends the run once. The first call wins.
    private func finish(_ result: String?) {
        lock.lock()
        let first = !finished
        finished = true
        let done = completion
        completion = nil
        lock.unlock()
        guard first else { return }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        done?(result)
    }

    /// Terminates the shell, and kills it when it ignores that.
    private func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
