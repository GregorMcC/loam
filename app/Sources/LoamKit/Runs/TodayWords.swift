import Foundation

/// The text of Today that is not the tiles or the line: the header, the events since you left, the limits, and the
/// card at the bottom of the sidebar.
public enum TodayWords {
    /// One row of a card: a label at the left and its value at the right.
    public struct Row: Equatable, Sendable {
        public var label: String
        public var value: String
    }

    /// "Wednesday 28 October · 2 of 3 running · 1 waits for a slot". The runs that hold a slot are running, and the
    /// limit is `at_a_time`. With no limits read, it is "2 running". The part about the queue is left out when no
    /// run waits.
    public static func caption(runs: [Run], limits: RunLimits?, now: Date, timeZone: TimeZone = .current) -> String {
        let running = runs.filter(\.state.holdsSlot).count
        let waiting = runs.filter { $0.state == .queued }.count
        var parts = [day(now, timeZone: timeZone)]
        parts.append(limits.map { "\(running) of \($0.atATime) running" } ?? "\(running) running")
        if waiting > 0 { parts.append(waiting == 1 ? "1 waits for a slot" : "\(waiting) wait for a slot") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "Wednesday 28 October".
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        let parts = calendar(timeZone).dateComponents([.weekday, .day, .month], from: date)
        return "\(weekdays[(parts.weekday ?? 1) - 1]) \(parts.day ?? 1) \(months[(parts.month ?? 1) - 1])"
    }

    /// "Monday 09:00".
    public static func weekdayAndClock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let weekday = calendar(timeZone).component(.weekday, from: date)
        return "\(weekdays[weekday - 1]) \(ChangeRules.stamp(date, now: date, timeZone: timeZone))"
    }

    /// "5 things need a decision from you. The desk shows them one at a time."
    public static func deskCaption(count: Int) -> String {
        switch count {
        case 0: "Nothing needs a decision from you."
        case 1: "1 thing needs a decision from you."
        default: "\(count) things need a decision from you. The desk shows them one at a time."
        }
    }

    // MARK: While you were away

    /// One event of a run since you left Today.
    public struct AwayRow: Equatable, Sendable, Identifiable {
        public var id: Int
        public var runID: String
        /// "HH:MM" today, else "2 Oct, HH:MM".
        public var time: String
        public var title: String
        public var detail: String
        /// The run stopped: the detail shows in rust.
        public var stopped: Bool
    }

    /// How many events "While you were away" shows.
    public static let awayLimit = 8

    /// The newest events first, at most `awayLimit`.
    public static func away(_ events: [RunFeedEvent], now: Date, timeZone: TimeZone = .current) -> [AwayRow] {
        events.prefix(awayLimit).enumerated().map { index, event in
            let state = event.kind == "state" ? RunState(rawValue: event.detail) : nil
            return AwayRow(id: index, runID: event.runID, time: ChangeRules.stamp(event.at, now: now, timeZone: timeZone),
                           title: event.runTitle, detail: eventWords(kind: event.kind, detail: event.detail),
                           stopped: state == .stopped || state == .limited)
        }
    }

    /// "Since 23:10", or "Nothing happened since 23:10" when no event came.
    public static func awayCaption(since: Date, empty: Bool, now: Date, timeZone: TimeZone = .current) -> String {
        let time = ChangeRules.stamp(since, now: now, timeZone: timeZone)
        return empty ? "Nothing happened since \(time)" : "Since \(time)"
    }

    /// The words of a run event: a state in the app's terms, a try that failed, or the detail as the core wrote it.
    public static func eventWords(kind: String, detail: String) -> String {
        switch kind {
        case "state": RunState(rawValue: detail)?.words ?? detail
        case "try": detail.isEmpty ? "A try failed" : detail
        default: detail
        }
    }

    // MARK: Limits

    /// The rows of the Limits card. `tries` is the tries of a new run.
    public static func limits(_ limits: RunLimits, tries: Int) -> [Row] {
        let turns = limits.maxTurns == 0 ? "No turn limit" : "\(limits.maxTurns) turns"
        return [
            Row(label: "At a time", value: limits.atATime == 1 ? "1 run" : "\(limits.atATime) runs"),
            Row(label: "Each run", value: "\(turns) \u{00B7} \(tries == 1 ? "1 try" : "\(tries) tries")"),
            Row(label: "Hold new runs at", value: limits.holdAt == 0 ? "Off" : "\(limits.holdAt)% of the week"),
            // Loam never merges a PR by itself: a run lands only when you land it.
            Row(label: "Merges", value: "Only by you"),
        ]
    }

    // MARK: The sidebar card

    /// The card at the bottom of the sidebar on Today: the runs that hold a slot, the usage of the week, the next
    /// recurring run, and when the week resets.
    public struct RunsCard: Equatable, Sendable {
        public var running: String
        /// The percent of the week's usage, such as "41%". Nil before Claude Code reports it.
        public var usage: String?
        /// From 0 to 1.
        public var usageFraction: Double
        /// "Next recurring run 22:00 · Resets Monday 09:00", or nil when neither is known.
        public var footer: String?
    }

    public static func runsCard(runs: [Run], limits: RunLimits?, usage: Usage?, recurring: [Recurring], now: Date,
                                timeZone: TimeZone = .current) -> RunsCard {
        let running = runs.filter(\.state.holdsSlot).count
        let week = usage?.sevenDay.flatMap { window in ChangeRules.date(window.resetsAt).map { (window, $0) } }
        // A week that reset is not known any more.
        let known = week.flatMap { $0.1 > now ? $0 : nil }
        let fraction = min(max(known?.0.utilization ?? 0, 0), 1)
        var footer: [String] = []
        if let next = recurring.compactMap({ ChangeRules.date($0.nextAt) }).filter({ $0 > now }).min() {
            footer.append("Next recurring run " + ChangeRules.stamp(next, now: now, timeZone: timeZone))
        }
        if let resets = known?.1 { footer.append("Resets " + weekdayAndClock(resets, timeZone: timeZone)) }
        return RunsCard(running: limits.map { "\(running) of \($0.atATime)" } ?? "\(running)",
                        usage: known.map { "\(Int(($0.0.utilization * 100).rounded()))%" }, usageFraction: fraction,
                        footer: footer.isEmpty ? nil : footer.joined(separator: " \u{00B7} "))
    }

    /// The card at the bottom of the sidebar on the Intake page: when the app last read each source of the plot.
    /// A kind with one source is named by the kind, such as "Linear", and a kind with more by each label.
    public static func sourcesCard(_ list: IntakeList, reads: [String: Date], now: Date) -> [Row] {
        list.sources.map { source in
            let many = list.sources.filter { $0.kind == source.kind }.count > 1
            let label = many ? source.label : kindWords(source.kind)
            let value = reads[sourceKey(source)].map { "Read " + ago(now.timeIntervalSince($0)) } ?? "Could not read"
            return Row(label: label, value: value)
        }
    }

    /// The key of a source in the read times of a plot.
    public static func sourceKey(_ source: IntakeSource) -> String { "\(source.kind):\(source.label)" }

    static func kindWords(_ kind: String) -> String {
        switch kind {
        case "linear": "Linear"
        case "github": "GitHub"
        case "map": "Map"
        default: kind
        }
    }

    /// "just now", "2 min ago", "3 h ago", or "2 d ago".
    public static func ago(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours) h ago" : "\(hours / 24) d ago"
    }

    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                                 "October", "November", "December"]

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
