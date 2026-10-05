import Foundation

/// The app's `state.json` in `~/Library/Application Support/Loam/`.
/// Several features write to this file: review (`last_seen_changes`), the switcher
/// (`switcher_use_times`), and restore (`panes`, `layout`, `window`; see `SavedLayout`).
/// Every write reads the whole file, changes one key, and writes it back, so keys that this type
/// does not know stay as they are. `LOAM_APP_STATE_DIR` replaces the folder, as the core reads it.
public struct AppStateFile: Sendable {
    public static let lastSeenKey = "last_seen_changes"

    public let url: URL

    public init(url: URL) { self.url = url }

    /// The standard file, or the file in the `LOAM_APP_STATE_DIR` folder.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let dir = environment["LOAM_APP_STATE_DIR"], !dir.isEmpty {
            url = URL(fileURLWithPath: dir).appendingPathComponent("state.json")
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Loam/state.json")
        }
    }

    public enum StateError: Error, Equatable { case unreadable }

    private static let lock = NSLock()

    /// Reads one key. A missing file or key gives nil.
    public func value(forKey key: String) -> Any? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return (try? readObject())?[key]
    }

    /// Sets one key and keeps every other key. A key set to nil is removed.
    /// A file that holds invalid JSON is not replaced: the call throws `StateError.unreadable`.
    public func setValue(_ value: Any?, forKey key: String) throws {
        try setValues([key: value ?? NSNull()])
    }

    /// Sets several keys in one write and keeps every other key. A key set to `NSNull()` is removed.
    /// A file that holds invalid JSON is not replaced.
    public func setValues(_ values: [String: Any]) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var object = try readObject()
        for (key, value) in values {
            if value is NSNull { object.removeValue(forKey: key) } else { object[key] = value }
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func readObject() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw StateError.unreadable
        }
        return object
    }

    // MARK: Last seen changes

    /// The highest change ID the person has seen, for each plot. Nil when the app never wrote the key.
    public func lastSeenChanges() -> [String: Int]? {
        guard let raw = value(forKey: Self.lastSeenKey) as? [String: Any] else { return nil }
        return raw.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    public func setLastSeenChanges(_ seen: [String: Int]) throws {
        try setValue(seen, forKey: Self.lastSeenKey)
    }
}
