import Foundation

/// Calls `onChange` when a repo's `HEAD` changes, so the window subtitle follows a checkout
/// (ticket 69). Git writes `HEAD.lock` and renames it over `HEAD`, which replaces the file. So the
/// watcher watches the git folder, not the file. The folder is found and opened off the main actor,
/// and the event handler reads nothing: it only calls `onChange` on the main queue.
@MainActor
public final class HeadWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var generation = 0
    private let onChange: @MainActor () -> Void

    public init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    /// Watches the repo at `path`, and stops watching the repo before it. Nil stops the watch.
    public func watch(repo path: String?) {
        stop()
        guard let path else { return }
        let mine = generation
        Task { [weak self] in
            let fd = await Task.detached { Self.open(repo: path) }.value
            guard let fd else { return }
            guard let self, self.generation == mine else { close(fd); return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.onChange() }
            }
            source.setCancelHandler { close(fd) }
            self.source = source
            source.resume()
        }
    }

    public func stop() {
        generation += 1
        source?.cancel()
        source = nil
    }

    /// Opens the git folder for events only. It reads files, so it runs off the main actor.
    nonisolated static func open(repo path: String) -> Int32? {
        let fd = Darwin.open(RepoLine.gitDirectory(path: path).path, O_EVTONLY)
        return fd < 0 ? nil : fd
    }
}
