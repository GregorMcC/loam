import CoreServices
import Foundation

/// Watches a folder with FSEvents. Each `Void` is one batch of file events.
public enum DirectoryWatcher {
    /// The default store folder, `~/.loam`.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".loam")
    }

    /// The store folder, resolved as the core does: `LOAM_HOME`, else `~/.loam`.
    public static func home(environment: [String: String] = [:]) -> URL {
        let value = environment["LOAM_HOME"] ?? ProcessInfo.processInfo.environment["LOAM_HOME"]
        if let value, !value.isEmpty {
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        return defaultDirectory
    }

    /// The files whose writes mean the store changed. The core rewrites `loam.changed` after each
    /// commit, because `loam mcp` keeps the database open and its writes raise no event until it exits.
    public static let storeFiles: Set<String> = ["loam.db", "loam.db-wal", "loam.changed"]

    /// Events for the store database in the home folder. Writes under `plots/` and `worktrees/` are ignored.
    public static func storeEvents(environment: [String: String] = [:], latency: TimeInterval = 0.05) -> AsyncStream<Void> {
        let dir = home(environment: environment)
        // FSEvents delivers nothing for a missing folder. The core creates it on first run.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return events(at: dir, latency: latency, onlyFiles: storeFiles)
    }

    /// Events for files under `directory`. The stream ends, and the watch stops, when the consumer stops.
    /// A read of the store can touch SQLite's shared-memory file, so events for `-shm` files are dropped.
    /// Without that, each poll would trigger the next. With `onlyFiles`, only events for files of those names count.
    public static func events(
        at directory: URL = defaultDirectory, latency: TimeInterval = 0.05, onlyFiles: Set<String>? = nil
    ) -> AsyncStream<Void> {
        events(at: [directory], latency: latency) { path in
            if path.hasSuffix("-shm") { return false }
            guard let onlyFiles else { return true }
            return onlyFiles.contains((path as NSString).lastPathComponent)
        }
    }

    /// Events under several folders. A batch counts when `accept` takes one of its file paths.
    /// The stream ends, and the watch stops, when the consumer stops.
    public static func events(
        at directories: [URL], latency: TimeInterval = 0.05, accept: @escaping @Sendable (String) -> Bool
    ) -> AsyncStream<Void> {
        AsyncStream { continuation in
            guard !directories.isEmpty else {
                continuation.finish()
                return
            }
            let box = Box(continuation, accept: accept)
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passRetained(box).toOpaque(),
                retain: nil, release: { Unmanaged<Box>.fromOpaque($0!).release() }, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                if list.contains(where: box.accept) {
                    box.continuation.yield()
                }
            }
            let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
            guard let stream = FSEventStreamCreate(
                nil, callback, &context, directories.map(\.path) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else {
                Unmanaged.passUnretained(box).release()
                continuation.finish()
                return
            }
            let queue = DispatchQueue(label: "loam.fsevents")
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            nonisolated(unsafe) let handle = stream
            continuation.onTermination = { _ in
                FSEventStreamStop(handle)
                FSEventStreamInvalidate(handle)
                FSEventStreamRelease(handle)
            }
        }
    }

    private final class Box: @unchecked Sendable {
        let continuation: AsyncStream<Void>.Continuation
        let accept: @Sendable (String) -> Bool
        init(_ c: AsyncStream<Void>.Continuation, accept: @escaping @Sendable (String) -> Bool) {
            continuation = c
            self.accept = accept
        }
    }
}
