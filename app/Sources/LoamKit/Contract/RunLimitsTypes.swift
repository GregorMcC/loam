import Foundation

/// The limits of every run: how many runs work at once, how many turns a run can take, and the share of the week's
/// usage at which new runs wait.
public struct RunLimits: Codable, Equatable, Sendable {
    /// How many runs can hold a slot at once, 1 to 20.
    public var atATime: Int
    /// How many turns a run can take. 0 means no limit.
    public var maxTurns: Int
    /// The percent of the 7-day usage at which new runs wait. 0 means no hold.
    public var holdAt: Int

    public init(atATime: Int, maxTurns: Int, holdAt: Int) {
        self.atATime = atATime
        self.maxTurns = maxTurns
        self.holdAt = holdAt
    }

    enum CodingKeys: String, CodingKey {
        case atATime = "at_a_time", maxTurns = "max_turns", holdAt = "hold_at"
    }
}

/// Output of `loam run limits`.
public struct RunLimitsOne: Codable, Equatable, Sendable {
    public var limits: RunLimits
}

/// The usage of one window of Claude Code's limits.
public struct UsageWindow: Codable, Equatable, Sendable {
    /// The share of the window that is used, from 0 to 1.
    public var utilization: Double
    /// When the window starts again.
    public var resetsAt: String

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// The last usage that Claude Code reported. A window is nil until Claude Code reports it.
public struct Usage: Codable, Equatable, Sendable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    /// When Loam read the usage. Nil before the first report.
    public var readAt: String?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour", sevenDay = "seven_day", readAt = "read_at"
    }
}

/// Output of `loam usage`.
public struct UsageOne: Codable, Equatable, Sendable {
    public var usage: Usage
}
