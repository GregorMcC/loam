import Foundation

/// A run that starts on a timetable (ticket 208), such as "Shape new issues" on weekdays at 06:30. `loam tick`
/// starts it when it is due and its precheck finds work.
public struct Recurring: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Claude drafts a run for you to approve.
        case shape
        /// A run starts and works to its gate.
        case chore
    }

    /// What a time that the Mac slept through does.
    public enum IfAsleep: String, Codable, Sendable {
        case once, skip
    }

    public var id: String
    public var plotID: String
    public var title: String
    /// What Claude does: the goal of a chore, or the brief of a Shape run.
    public var prompt: String
    public var kind: Kind
    /// The days of the week, in its order: sun, mon, and so on.
    public var days: [String]
    /// The time of day, HH:MM.
    public var at: String
    /// A shell command in the repo. The run starts only when it exits 0. Empty starts it each time.
    public var precheck: String
    public var ifAsleep: IfAsleep
    public var repo: String
    public var doneWhen: [RunCheck]
    public var maxTries: Int
    public var model: String
    public var nextAt: String
    /// When a tick last took it, or nil before the first time.
    public var lastAt: String?
    /// What the last tick did, for a person to read.
    public var lastNote: String
    public var lastRunID: String
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, prompt, kind, days, at, precheck, repo, model
        case plotID = "plot_id", ifAsleep = "if_asleep", doneWhen = "done_when", maxTries = "max_tries"
        case nextAt = "next_at", lastAt = "last_at", lastNote = "last_note", lastRunID = "last_run_id"
        case createdAt = "created_at"
    }
}

/// Output of `loam recurring add` and `loam recurring rm`.
public struct RecurringOne: Codable, Equatable, Sendable {
    public var recurring: Recurring
}

/// Output of `loam recurring list`.
public struct RecurringList: Codable, Equatable, Sendable {
    public var recurring: [Recurring]
}

/// What a tick did with one recurring run. Output of `loam recurring run`.
public struct RecurringResult: Codable, Equatable, Sendable {
    public var recurring: Recurring
    /// The run that the tick started or skipped, or nil when it made none.
    public var run: Run?
    public var note: String
}

/// Output of `loam tick`.
public struct TickResult: Codable, Equatable, Sendable {
    public var recurring: [RecurringResult]
    public var runs: [Run]
    public var warnings: [String]
}

/// Output of `loam tick status`, `install`, and `uninstall`: whether launchd runs `loam tick` while the app is
/// closed.
public struct TickStatus: Codable, Equatable, Sendable {
    public struct LastTick: Codable, Equatable, Sendable {
        public var at: String
        public var error: String
    }

    public var installed: Bool
    public var plist: String
    /// Seconds between ticks.
    public var interval: Int
    public var lastTick: LastTick?

    enum CodingKeys: String, CodingKey {
        case installed, plist, interval
        case lastTick = "last_tick"
    }
}
