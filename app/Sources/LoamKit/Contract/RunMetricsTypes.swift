import Foundation

/// The median and the 90th percentile of some times, in seconds, by the nearest rank. Both are 0 when count is 0.
public struct MetricsSpread: Codable, Equatable, Sendable {
    public var count: Int
    public var medianSeconds: Int
    public var p90Seconds: Int

    enum CodingKeys: String, CodingKey {
        case count, medianSeconds = "median_seconds", p90Seconds = "p90_seconds"
    }
}

/// The time that the landed runs spent at each station. Approve holds only the runs that had a draft.
public struct MetricsStations: Codable, Equatable, Sendable {
    public var approve: MetricsSpread
    public var queue: MetricsSpread
    public var build: MetricsSpread
    public var ship: MetricsSpread
    public var merge: MetricsSpread
    public var stopped: MetricsSpread
}

/// The time from a failed gate, or a failed CI, to the next pass.
public struct MetricsRecovery: Codable, Equatable, Sendable {
    public var gate: MetricsSpread
    public var ci: MetricsSpread
}

/// The sums of the loops of the landed runs.
public struct MetricsRework: Codable, Equatable, Sendable {
    public var gateTries: Int
    public var ciTries: Int
    public var reviewTries: Int
    /// The code reviews before a push that found a Critical or Major issue.
    public var codeReviewRounds: Int
    /// The drafts after the first one.
    public var redrafts: Int
    public var turns: Int

    enum CodingKeys: String, CodingKey {
        case gateTries = "gate_tries", ciTries = "ci_tries", reviewTries = "review_tries"
        case codeReviewRounds = "code_review_rounds", redrafts, turns
    }
}

/// The runs that ended, or wait for you, in the window with no land, by state.
public struct MetricsNotLanded: Codable, Equatable, Sendable {
    public var stopped: Int
    public var limited: Int
    public var cancelled: Int
    public var startUnknown: Int

    enum CodingKeys: String, CodingKey {
        case stopped, limited, cancelled, startUnknown = "start_unknown"
    }
}

/// A landed run and its lead time.
public struct MetricsSlowRun: Codable, Equatable, Sendable {
    public var runID: String
    public var plotID: String
    public var title: String
    public var leadSeconds: Int

    enum CodingKeys: String, CodingKey {
        case title, runID = "run_id", plotID = "plot_id", leadSeconds = "lead_seconds"
    }
}

/// The run metrics of one window. A landed run counts in the window that it landed in.
public struct MetricsPeriod: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var landed: Int
    /// The landed runs that used no try and no review try.
    public var firstPass: Int
    /// The landed runs that a later run fixes: the change failures.
    public var fixed: Int
    /// From approve to landed.
    public var leadTime: MetricsSpread
    public var stations: MetricsStations
    public var recovery: MetricsRecovery
    public var rework: MetricsRework
    public var notLanded: MetricsNotLanded
    /// The landed runs with the longest lead time, longest first, at most 5.
    public var slowest: [MetricsSlowRun]

    enum CodingKeys: String, CodingKey {
        case from, to, landed, fixed, stations, recovery, rework, slowest
        case firstPass = "first_pass", leadTime = "lead_time", notLanded = "not_landed"
    }
}

/// Output of `loam run metrics`: the window up to now, and the window of the same length before it.
public struct RunMetrics: Codable, Equatable, Sendable {
    public var current: MetricsPeriod
    public var previous: MetricsPeriod
}
