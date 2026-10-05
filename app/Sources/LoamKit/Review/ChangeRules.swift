import Foundation

/// The rules of review (spec 8.6) as pure functions on the change log. The review model and the tests use them.
public enum ChangeRules {
    /// A change counts as new when it is not yours and its ID is above the last-seen ID of its plot.
    /// A change from the app or the CLI is yours and never counts.
    public static func isNew(_ change: Change, lastSeen: Int) -> Bool {
        change.actor.kind == .session && change.id > lastSeen
    }

    /// The new changes of one plot, newest first.
    public static func newChanges(in changes: [Change], plot: String, lastSeen: Int) -> [Change] {
        changes.filter { $0.plotID == plot && isNew($0, lastSeen: lastSeen) }.sorted { $0.id > $1.id }
    }

    /// The count of new changes for each plot. A plot with none is not in the result.
    public static func newCounts(in changes: [Change], lastSeen: [String: Int]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for change in changes where isNew(change, lastSeen: lastSeen[change.plotID] ?? 0) {
            counts[change.plotID, default: 0] += 1
        }
        return counts
    }

    /// The change log of one plot, newest first.
    public static func log(in changes: [Change], plot: String) -> [Change] {
        changes.filter { $0.plotID == plot }.sorted { $0.id > $1.id }
    }

    /// One page of the change log. Page 0 holds the newest changes.
    public struct LogPage: Equatable, Sendable {
        public var changes: [Change]
        /// The page shown, clamped to the pages that exist.
        public var index: Int
        /// The number of pages. An empty log has one empty page.
        public var count: Int
        /// "11 to 20 of 47".
        public var range: String
        public var hasNewer: Bool { index > 0 }
        public var hasOlder: Bool { index < count - 1 }
    }

    public static let logPageSize = 10

    /// Page `index` of a log that is newest first, `size` changes to a page.
    public static func page(of log: [Change], index: Int, size: Int = logPageSize) -> LogPage {
        let count = max(1, (log.count + size - 1) / size)
        let index = min(max(index, 0), count - 1)
        let start = index * size
        let end = min(start + size, log.count)
        let range = log.isEmpty ? "" : "\(start + 1) to \(end) of \(log.count)"
        return LogPage(changes: Array(log[start..<end]), index: index, count: count, range: range)
    }

    /// The highest change ID of one plot, or nil when the plot has no change.
    public static func newestID(in changes: [Change], plot: String) -> Int? {
        changes.lazy.filter { $0.plotID == plot }.map(\.id).max()
    }

    /// Plot creation holds the `name` item as a new item. It has no Undo.
    public static func isCreation(_ change: Change) -> Bool {
        change.entries.contains { $0.item == "name" && $0.old == nil }
    }

    public static func canUndo(_ change: Change) -> Bool { !isCreation(change) }

    /// The change that undid `change`, if any.
    public static func undoingChange(of change: Change, in changes: [Change]) -> Change? {
        changes.first { $0.undoOf == change.id }
    }

    /// "HH:MM" of an RFC 3339 time, in `timeZone`. Falls back to the text when it does not parse.
    public static func clock(_ at: String, timeZone: TimeZone = .current) -> String {
        guard let date = wholeSeconds.date(from: at) ?? fractionalSeconds.date(from: at) else { return at }
        let parts = gregorian.dateComponents(in: timeZone, from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The time of a change for the panel: "HH:MM" on the day of `now`, else "2 Oct, HH:MM".
    public static func stamp(_ at: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let date = wholeSeconds.date(from: at) ?? fractionalSeconds.date(from: at) else { return at }
        var calendar = gregorian
        calendar.timeZone = timeZone
        let time = clock(at, timeZone: timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let parts = calendar.dateComponents([.day, .month], from: date)
        return "\(parts.day ?? 1) \(months[((parts.month ?? 1) - 1) % 12]), \(time)"
    }

    /// `clock` runs for every row of the log, so the parsers and the calendar are made once. An
    /// `ISO8601DateFormatter` is thread-safe but not `Sendable`, so it carries the unsafe mark.
    nonisolated(unsafe) private static let wholeSeconds = iso8601Parser([.withInternetDateTime])
    nonisolated(unsafe) private static let fractionalSeconds = iso8601Parser([.withInternetDateTime, .withFractionalSeconds])
    private static let gregorian = Calendar(identifier: .gregorian)

    private static func iso8601Parser(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = options
        return parser
    }

    // MARK: Showing a change

    /// One shown field of a change.
    public struct EntryView: Equatable, Sendable {
        public enum Body: Equatable, Sendable {
            /// An edit of text: removed and added words.
            case words([WordDiff.Segment])
            /// A new item or field, in full.
            case added(String)
            /// A removed item or field, in full.
            case removed(String)
        }
        /// For example "Where it stands", or "Link spec: target".
        public var title: String
        public var body: Body
    }

    public static func itemTitle(_ item: String) -> String {
        switch item {
        case "name": return "Name"
        case "what": return "What"
        case "why": return "Why"
        case "where": return "Where it stands"
        default:
            if item.hasPrefix("link:") { return "Link" }
            if item.hasPrefix("repo:") { return "Repo" }
            return item
        }
    }

    /// The fields to show for a change. A link or repo field `position` is not shown.
    /// Text edits show per word. An added or removed link or repo shows in full.
    public static func entryViews(_ change: Change) -> [EntryView] {
        change.entries.compactMap { entry in
            guard entry.field != "position" else { return nil }
            let base = itemTitle(entry.item)
            let title = entry.field == "value" ? base : "\(base) \(entry.field)"
            switch (entry.old, entry.new) {
            case let (old?, new?):
                return EntryView(title: title, body: .words(WordDiff.diff(old: old, new: new)))
            case let (nil, new?):
                return EntryView(title: title, body: .added(new))
            case let (old?, nil):
                return EntryView(title: title, body: .removed(old))
            case (nil, nil):
                return nil
            }
        }
    }

    /// One line for the log, such as "Edited What, Where it stands" or "Added link".
    public static func summary(_ change: Change) -> String {
        if isCreation(change) { return "Created the plot" }
        if let target = change.undoOf { return "Undid change \(target)" }
        var parts: [String] = []
        var seen = Set<String>()
        for entry in change.entries where entry.field != "position" && seen.insert(entry.item).inserted {
            let isStructured = entry.item.hasPrefix("link:") || entry.item.hasPrefix("repo:")
            let title = isStructured ? itemTitle(entry.item).lowercased() : itemTitle(entry.item)
            let fields = change.entries.filter { $0.item == entry.item }
            let verb: String
            if isStructured, fields.allSatisfy({ $0.old == nil }) { verb = "Added" }
            else if isStructured, fields.allSatisfy({ $0.new == nil }) { verb = "Removed" }
            else { verb = "Edited" }
            parts.append("\(verb) \(title)")
        }
        return parts.isEmpty ? "Changed the plot" : parts.joined(separator: ", ")
    }
}
