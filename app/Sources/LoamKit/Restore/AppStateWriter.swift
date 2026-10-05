import Foundation
import OSLog

/// The one writer of `state.json` for the layout (spec 8.5) and the switcher use times.
///
/// A change only marks its part as changed. The first change starts a wait of `delay`, and at
/// the end of the wait one write takes every change since: at most one write per `delay`. The
/// write runs on a background queue, so the main thread never waits for the disk. Quit calls
/// `suspend()`, which writes what is pending at once, so nothing is lost. A crash loses at most
/// the changes of the last `delay`.
///
/// The layout is built only when a write starts, not at each change. It is written only when it
/// differs from the last layout written, so a hook line that changes only working or idle writes
/// nothing.
@MainActor
public final class AppStateWriter {
    public let file: AppStateFile
    public let delay: Duration
    /// Builds the layout to write. `AppModel` sets it. Nil writes no layout.
    public var layout: (@MainActor () -> SavedLayout?)?
    /// How many writes started. Tests read it.
    public private(set) var writeCount = 0
    public private(set) var isSuspended = false
    /// A change waits for a write. Tests read it.
    var hasPending: Bool { layoutChanged || !changedKeys.isEmpty }

    private var layoutChanged = false
    private var lastLayout: SavedLayout?
    /// The function that gives the current value of each other key. It stays after a write.
    private var sources: [String: @MainActor () -> Any] = [:]
    /// The other keys that changed since the last write.
    private var changedKeys: Set<String> = []
    private var timer: Task<Void, Never>?
    /// Writes in order, off the main thread.
    private let io = DispatchQueue(label: "dev.loam.state-writer")

    public init(file: AppStateFile, delay: Duration = .seconds(1)) {
        self.file = file
        self.delay = delay
    }

    /// The layout changed. The next write builds it. Nothing happens after `suspend()`.
    public func setLayoutChanged() {
        guard !isSuspended else { return }
        layoutChanged = true
        schedule()
    }

    /// The value of `key` changed. The next write calls `value` once, so it writes the value of
    /// that moment. Nothing happens after `suspend()`.
    public func setChanged(_ key: String, value: @escaping @MainActor () -> Any) {
        guard !isSuspended else { return }
        sources[key] = value
        changedKeys.insert(key)
        schedule()
    }

    /// Writes what is pending now, and waits until the write is done. Quit and tests call it.
    public func flush() {
        let values = takePending()
        io.sync { if let values { self.write(values) } }
    }

    /// Writes what is pending now, and waits off the main thread until the write is done. Call it
    /// before the core reads `state.json` (`loam worktree rm` reads the panes).
    public func flushed() async {
        let values = takePending()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            io.async {
                if let values { self.write(values) }
                done.resume()
            }
        }
    }

    /// Writes what is pending, then stops all writes. Quit calls it after the last change, so
    /// closing the panes keeps them in the file. A failed write here is not tried again.
    public func suspend() {
        guard !isSuspended else { return }
        flush()
        isSuspended = true
    }

    private func schedule() {
        guard timer == nil else { return }
        let delay = delay
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            guard let values = self.collect() else { return }
            self.io.async { self.write(values) }
        }
    }

    private func takePending() -> Values? {
        timer?.cancel()
        timer = nil
        return collect()
    }

    /// The values of every change since the last write, or nil when nothing needs a write.
    private func collect() -> Values? {
        var values: [String: Any] = [:]
        for key in changedKeys { values[key] = sources[key]?() }
        let keys = changedKeys
        changedKeys = []
        var hasLayout = false
        if layoutChanged {
            layoutChanged = false
            if let built = layout?(), built != lastLayout {
                do {
                    values.merge(try built.jsonValues()) { $1 }
                    lastLayout = built
                    hasLayout = true
                } catch {
                    writerLog.error("state.json layout encode failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        guard !values.isEmpty else { return nil }
        writeCount += 1
        return Values(values: values, keys: keys, hasLayout: hasLayout)
    }

    /// Runs on `io`.
    nonisolated private func write(_ values: Values) {
        do {
            try file.setValues(values.values)
        } catch {
            // The file holds invalid JSON, or the folder is not writable. The keys count as
            // changed again, so the next write (at the next change, or at quit) tries them again
            // with their values of that moment.
            writerLog.error("state.json write failed: \(String(describing: error), privacy: .public)")
            Task { @MainActor [weak self] in self?.writeFailed(values) }
        }
    }

    private func writeFailed(_ values: Values) {
        changedKeys.formUnion(values.keys)
        if values.hasLayout {
            lastLayout = nil
            layoutChanged = true
        }
    }

    /// JSON values, made on the main actor and not changed after, so they can cross to `io`.
    private struct Values: @unchecked Sendable {
        let values: [String: Any]
        /// The other keys in `values`, by name.
        let keys: Set<String>
        let hasLayout: Bool
    }
}

private let writerLog = Logger(subsystem: "dev.loam.Loam", category: "state")
