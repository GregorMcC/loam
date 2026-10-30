import Foundation

/// The words and the numbers of the Metrics page for a person (TAS-176).
public enum MetricsWords {
    /// One station of the lead time, with its median time and its share of the bar.
    public struct Station: Equatable, Sendable {
        public var name: String
        public var spread: MetricsSpread
        /// The median of this station over the sum of the medians, from 0 to 1. 0 when every median is 0.
        public var share: Double
    }

    /// "Metrics · Loam v1 build", or "Metrics" for every plot.
    public static func pageTitle(plot: String?) -> String {
        guard let plot, !plot.isEmpty else { return "Metrics" }
        return "Metrics \u{00B7} \(plot)"
    }

    /// A time for a person: "45s", "22m", "1h 32m", or "2d 4h".
    public static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        // The unit comes from the rounded minutes, so 59m 59s is "1h", not "60m".
        let minutes = (s + 30) / 60
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m" }
        let hours = (s + 1800) / 3600
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    /// The median and the 90th percentile of a spread, such as "22m, 90th 50m", or "None" when it is empty.
    public static func spread(_ spread: MetricsSpread) -> String {
        guard spread.count > 0 else { return "None" }
        return "\(duration(spread.medianSeconds)), 90th \(duration(spread.p90Seconds))"
    }

    /// The time from the draft to the approval, such as "3m, 90th 3m (1 drafted run)". Only drafted runs have it.
    public static func approve(_ spread: MetricsSpread) -> String {
        guard spread.count > 0 else { return "None" }
        return "\(self.spread(spread)) (\(count(spread.count, "drafted run", "drafted runs") ?? ""))"
    }

    /// The stations after approve, in the order that a run passes them. They add up to the lead time of a run.
    public static func stations(_ period: MetricsPeriod) -> [Station] {
        let s = period.stations
        let all = [("Queue", s.queue), ("Build", s.build), ("Ship", s.ship), ("Merge", s.merge), ("Stopped", s.stopped)]
        let total = Double(all.reduce(0) { $0 + $1.1.medianSeconds })
        return all.map { Station(name: $0.0, spread: $0.1, share: total > 0 ? Double($0.1.medianSeconds) / total : 0) }
    }

    /// The station with the largest median, where most of the time goes, or nil when no run landed.
    public static func slowestStation(_ period: MetricsPeriod) -> Station? {
        let all = stations(period)
        guard period.landed > 0, let top = all.max(by: { $0.spread.medianSeconds < $1.spread.medianSeconds }),
              top.spread.medianSeconds > 0 else { return nil }
        return top
    }

    /// The median lead time against the window before: "12m faster than the 30 days before", "slower", "the same", or
    /// "No run landed in the 30 days before." Nil when no run landed in this window.
    public static func trend(_ metrics: RunMetrics) -> String? {
        let now = metrics.current.leadTime, before = metrics.previous.leadTime
        guard now.count > 0 else { return nil }
        let days = windowDays(metrics.previous)
        guard before.count > 0 else { return "No run landed in the \(days) days before." }
        let change = now.medianSeconds - before.medianSeconds
        if abs(change) < 60 { return "The same as the \(days) days before." }
        return "\(duration(abs(change))) \(change < 0 ? "faster" : "slower") than the \(days) days before."
    }

    /// The days of a window, rounded.
    public static func windowDays(_ period: MetricsPeriod) -> Int {
        guard let from = RecurringWords.parse(period.from), let to = RecurringWords.parse(period.to) else { return 0 }
        return Int((to.timeIntervalSince(from) / 86400).rounded())
    }

    /// "4 of 5", or "None" when no run landed.
    public static func share(_ count: Int, of total: Int) -> String {
        total > 0 ? "\(count) of \(total)" : "None"
    }

    /// The landed runs for each week of the window, such as "1.2 a week".
    public static func perWeek(_ period: MetricsPeriod) -> String {
        let days = windowDays(period)
        guard days > 0 else { return "" }
        let rate = Double(period.landed) / Double(days) * 7
        let text = rate.formatted(.number.precision(.fractionLength(0...1)))
        return "\(text) a week"
    }

    /// The rework of the landed runs, such as "2 gate tries · 1 CI try · 3 redrafts", or "No rework" when it has none.
    public static func rework(_ r: MetricsRework) -> String {
        let parts = [
            count(r.gateTries, "gate try", "gate tries"), count(r.ciTries, "CI try", "CI tries"),
            count(r.reviewTries, "review try", "review tries"),
            count(r.codeReviewRounds, "code review round", "code review rounds"),
            count(r.redrafts, "redraft", "redrafts"),
        ].compactMap { $0 }
        return parts.isEmpty ? "No rework" : parts.joined(separator: " \u{00B7} ")
    }

    /// The runs that did not land, such as "1 stopped · 2 cancelled", or "None" when every run landed.
    public static func notLanded(_ n: MetricsNotLanded) -> String {
        let parts = [
            count(n.stopped, "stopped", "stopped"), count(n.limited, "limited", "limited"),
            count(n.cancelled, "cancelled", "cancelled"), count(n.startUnknown, "start unknown", "start unknown"),
        ].compactMap { $0 }
        return parts.isEmpty ? "None" : parts.joined(separator: " \u{00B7} ")
    }

    /// "1 redraft" or "3 redrafts", or nil for 0.
    static func count(_ n: Int, _ one: String, _ many: String) -> String? {
        n == 0 ? nil : "\(n) \(n == 1 ? one : many)"
    }
}
