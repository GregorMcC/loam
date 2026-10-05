import Foundation

/// One update of the change feed.
public enum FeedUpdate: Equatable, Sendable {
    /// New changes across all plots, oldest first. Never empty.
    case changes([Change])
    /// A poll that a trigger started found nothing new. The core can still have changed (`move`, `archive`, `unarchive`
    /// and `delete` write no change), so a reader that shows plots reloads on this too.
    case unchanged
    /// A poll failed. The feed keeps running and retries on the next event.
    case failure(LoamError)
}

/// The app's change feed. A trigger (a file event) starts a debounce. When the triggers stop for
/// `debounce`, the feed runs `loam changes --since <id> --json` and publishes what is new.
/// Polls never overlap. A trigger during a poll runs one more poll.
public struct ChangeFeed: Sendable {
    public typealias Fetch = @Sendable (_ since: Int?) async throws -> [Change]

    private let fetch: Fetch
    private let makeTriggers: @Sendable () -> AsyncStream<Void>
    private let debounce: Duration
    private let after: Int?

    /// - Parameters:
    ///   - after: The highest change ID the UI has. Nil reads the log once at start to find it, and publishes nothing.
    public init(fetch: @escaping Fetch, triggers: AsyncStream<Void>, debounce: Duration = .milliseconds(250), after: Int? = nil) {
        self.init(fetch: fetch, makeTriggers: { triggers }, debounce: debounce, after: after)
    }

    /// `makeTriggers` runs when `updates()` starts, so nothing watches before then.
    public init(fetch: @escaping Fetch, makeTriggers: @escaping @Sendable () -> AsyncStream<Void>, debounce: Duration = .milliseconds(250), after: Int? = nil) {
        self.fetch = fetch
        self.makeTriggers = makeTriggers
        self.debounce = debounce
        self.after = after
    }

    /// Watches the store files and polls through `client`. The home is `LOAM_HOME` from
    /// `client.environment`, else from the app's environment, else `~/.loam`.
    /// Only `loam.db`, `loam.db-wal`, and `loam.changed` count, so writes under `plots/` and `worktrees/` start no poll.
    public init(
        client: LoamClient, debounce: Duration = .milliseconds(250), after: Int? = nil
    ) {
        let environment = client.environment
        self.init(
            fetch: { try await client.changes(since: $0) },
            makeTriggers: { DirectoryWatcher.storeEvents(environment: environment) },
            debounce: debounce, after: after)
    }

    /// Starts the feed. Stop it by ending the loop that reads the stream.
    public func updates() -> AsyncStream<FeedUpdate> {
        AsyncStream { continuation in
            let poller = Poller(fetch: fetch, cursor: after, continuation: continuation)
            let debounce = debounce
            let triggers = makeTriggers()
            let polls = PollSet()
            let task = Task {
                await poller.poll(idleUpdate: false)  // Baseline when `after` is nil. Also catches changes made before the watch began.
                var pending: Task<Void, Never>?
                for await _ in triggers {
                    pending?.cancel()  // Cancels the sleep only. A poll in progress runs on a detached task.
                    pending = Task {
                        try? await Task.sleep(for: debounce)
                        guard !Task.isCancelled else { return }
                        // Detached, so a later trigger cannot cancel the poll and kill the child.
                        let poll = Task.detached { await poller.poll(idleUpdate: true) }
                        polls.add(poll)
                        await poll.value
                    }
                }
                await pending?.value
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                polls.cancelAll()  // Stops a running `loam changes` child.
            }
        }
    }

    private actor Poller {
        let fetch: Fetch
        var cursor: Int?
        let continuation: AsyncStream<FeedUpdate>.Continuation
        var polling = false
        var dirty = false
        var publishIdle = false

        init(fetch: @escaping Fetch, cursor: Int?, continuation: AsyncStream<FeedUpdate>.Continuation) {
            self.fetch = fetch
            self.cursor = cursor
            self.continuation = continuation
        }

        func poll(idleUpdate: Bool) async {
            if idleUpdate { publishIdle = true }  // A trigger joined the poll in progress.
            if polling { dirty = true; return }
            polling = true
            defer { polling = false }
            repeat {
                dirty = false
                let idle = publishIdle
                publishIdle = false
                await pollOnce(idleUpdate: idle)
            } while dirty
        }

        private func pollOnce(idleUpdate: Bool) async {
            do {
                let changes = try await fetch(cursor)
                let top = changes.map(\.id).max()
                if cursor == nil {
                    // Baseline: remember the highest ID and publish nothing.
                    cursor = top ?? 0
                    return
                }
                if let top {
                    cursor = max(cursor ?? 0, top)
                    continuation.yield(.changes(changes))
                } else if idleUpdate {
                    continuation.yield(.unchanged)
                }
            } catch is CancellationError {
                return  // The feed stopped. Not a failure.
            } catch let error as LoamError {
                continuation.yield(.failure(error))
            } catch {
                continuation.yield(.failure(.launchFailed(error.localizedDescription)))
            }
        }
    }
}

/// Holds the detached polls, so the end of the feed can cancel them.
private final class PollSet: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var closed = false

    func add(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if closed { task.cancel() } else { tasks.append(task) }
    }

    func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        tasks.forEach { $0.cancel() }
        tasks = []
    }
}
