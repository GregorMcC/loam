import Foundation

/// Where a run is. `shaping`, `stopped`, and `limited` need you.
public enum RunState: String, Codable, Equatable, Sendable, CaseIterable {
    case shaping, starting, running, shipping, ready, stopped, limited
    case startUnknown = "start_unknown"
    case landed, cancelled, skipped
    /// A state that this app does not know.
    case unknown = ""

    /// A state that this app does not know decodes as `.unknown`, so a newer core does not break
    /// the list.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RunState(rawValue: raw) ?? .unknown
    }

    /// Shaping, Stopped, and Stopped by a limit wait for you.
    public var needsYou: Bool { self == .shaping || self == .stopped || self == .limited }

    /// The run has no session to work any more.
    public var ended: Bool { self == .landed || self == .cancelled || self == .skipped }

    /// The words for the state, in the app's terms.
    public var words: String {
        switch self {
        case .shaping: "Shape"
        case .starting: "Starting"
        case .running: "Running"
        case .shipping: "Shipping"
        case .ready: "Ready to land"
        case .stopped: "Stopped"
        case .limited: "Stopped by a limit"
        case .startUnknown: "Start unknown"
        case .landed: "Landed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        case .unknown: "Unknown"
        }
    }
}

/// A Done when check of a run: a shell command that passes when it exits 0 in the run's folder.
public struct RunCheck: Codable, Equatable, Sendable {
    public var name: String
    public var command: String
    public init(name: String, command: String) {
        self.name = name
        self.command = command
    }
}

/// The issue that a run started from.
public struct RunSource: Codable, Equatable, Sendable {
    /// linear, github, map, or recurring.
    public var kind: String
    public var key: String
    public var url: String
}

/// The pull request that Loam opened for a run (ticket 206).
public struct RunPR: Codable, Equatable, Sendable {
    public var number: Int
    public var url: String
}

/// One goal that a background Claude Code session works on in a worktree, until its checks pass.
public struct Run: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var plotID: String
    /// The worktree of the run. It can be gone. Empty for a run in a repo folder.
    public var worktreeID: String
    public var folder: String
    public var title: String
    public var goal: String
    public var doneWhen: [RunCheck]
    public var state: RunState
    /// How many times the gate or CI failed.
    public var tries: Int
    public var maxTries: Int
    public var source: RunSource?
    /// The PR of the run. Nil before the run ships.
    public var pr: RunPR? = nil
    /// The Claude Code session. Empty until the session starts.
    public var sessionID: String
    /// Why the run is in its state, such as the failed checks.
    public var note: String
    public var createdAt: String
    public var updatedAt: String
    enum CodingKeys: String, CodingKey {
        case id, folder, title, goal, state, tries, source, pr, note
        case plotID = "plot_id", worktreeID = "worktree_id", doneWhen = "done_when", maxTries = "max_tries"
        case sessionID = "session_id", createdAt = "created_at", updatedAt = "updated_at"
    }

    /// The short ID that `claude attach`, `logs`, and `stop` take: the start of the session ID.
    /// Nil until the session starts.
    public var shortSessionID: String? {
        sessionID.count >= 8 ? String(sessionID.prefix(8)) : nil
    }
}

/// One line of a run's history.
public struct RunEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var runID: String
    public var at: String
    /// state, try, check, linear, ship, or ci.
    public var kind: String
    public var detail: String
    enum CodingKeys: String, CodingKey { case id, at, kind, detail, runID = "run_id" }
}

/// Output of `loam run start`.
public struct RunStartResult: Codable, Equatable, Sendable {
    public var run: Run
    public var worktree: Worktree
}

/// Output of `loam run status`.
public struct RunStatus: Codable, Equatable, Sendable {
    public var run: Run
    public var events: [RunEvent]
}

/// Output of `loam run stop`.
public struct RunStopResult: Codable, Equatable, Sendable {
    public var run: Run
}

/// Output of `loam run tick` (ticket 206): the runs that the tick moved.
public struct RunTickResult: Codable, Equatable, Sendable {
    public var runs: [Run]
    public var warnings: [String]
}
