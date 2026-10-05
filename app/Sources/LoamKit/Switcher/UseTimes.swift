import Foundation

/// When each plot, pane, and link was last used. The switcher ranks by these times.
/// They live in `state.json` under `switcher_use_times`, as seconds since 1970 by item ID.
/// The writes go through the app's one `AppStateWriter`, which joins them into at most one
/// write per second, off the main thread. The file keeps every other key (see `AppStateFile`).
@MainActor
public final class UseTimes {
    public static let key = "switcher_use_times"
    /// The file keeps the newest entries only, so dead pane IDs do not pile up.
    static let limit = 500

    private let writer: AppStateWriter
    private var times: [String: Date]

    public init(writer: AppStateWriter) {
        self.writer = writer
        let raw = writer.file.value(forKey: Self.key) as? [String: Any] ?? [:]
        times = raw.compactMapValues { ($0 as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
    }

    public var all: [String: Date] { times }

    public func record(_ id: String, at date: Date = Date()) {
        times[id] = date
        if times.count > Self.limit {
            let oldest = times.sorted { $0.value < $1.value }.prefix(times.count - Self.limit)
            for (stale, _) in oldest { times[stale] = nil }
        }
        writer.setChanged(Self.key) { [self] in times.mapValues { $0.timeIntervalSince1970 } }
    }
}
