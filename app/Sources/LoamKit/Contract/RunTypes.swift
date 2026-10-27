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

    /// The source for a person: the key of an issue, or "Recurring" for a run that a recurring run started, whose
    /// key is an ID.
    public var label: String { kind == "recurring" ? "Recurring" : key }
}

/// The pull request that Loam opened for a run (ticket 206).
public struct RunPR: Codable, Equatable, Sendable {
    public var number: Int
    public var url: String
}

/// One choice of a draft that the issue does not settle (ticket 207).
public struct RunAssumption: Codable, Equatable, Sendable {
    public var text: String
    /// What you want instead, or empty when you keep the assumption.
    public var answer: String

    public init(text: String, answer: String = "") {
        self.text = text
        self.answer = answer
    }
}

/// The draft of a run that started in Shaping: what Claude made of the issue besides the goal and the checks, and
/// how the run starts when you approve it (ticket 207).
public struct RunShape: Codable, Equatable, Sendable {
    public var assumptions: [RunAssumption]
    public var plan: [String]
    public var size: String
    /// When Claude finished the last draft. Nil while the run has no draft.
    public var draftedAt: String?
    public var repo: String
    public var base: String
    public var link: String
    public var model: String
    /// What Claude drafts from when the run has no issue, such as the prompt of a recurring run.
    public var brief: String? = nil

    /// Claude has drafted the run, so you can approve it.
    public var isDrafted: Bool { draftedAt != nil }

    enum CodingKeys: String, CodingKey {
        case assumptions, plan, size, repo, base, link, model, brief
        case draftedAt = "drafted_at"
    }
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
    /// The draft of a run that started in Shaping, or nil.
    public var shape: RunShape? = nil
    /// The Claude Code session. Empty until the session starts.
    public var sessionID: String
    /// Why the run is in its state, such as the failed checks.
    public var note: String
    public var createdAt: String
    public var updatedAt: String
    /// The run waits on GitHub, so a tick can move it: it ships, or it is ready with a PR that GitHub can merge.
    public var waitsOnGitHub: Bool { state == .shipping || (state == .ready && pr != nil) }

    enum CodingKeys: String, CodingKey {
        case id, folder, title, goal, state, tries, source, pr, shape, note
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

/// Output of `loam run stop` and `loam run send-back`: the run after the change. A send-back has a rule offer when
/// a note is like a note that you sent back on another run of the plot (ticket 209).
public struct RunResult: Codable, Equatable, Sendable {
    public var run: Run
    public var ruleOffer: RuleOffer?

    enum CodingKeys: String, CodingKey {
        case run
        case ruleOffer = "rule_offer"
    }
}

/// Output of `loam run land` (ticket 207): the run after the land, and what the land of its worktree did.
public struct RunLandResult: Codable, Equatable, Sendable {
    public var run: Run
    public var land: LandResult
    public var warnings: [String]
}

/// Output of `loam run diff` (ticket 207): the work that a run committed, from `base`, where its branch left its
/// base, to `head`.
public struct RunDiff: Codable, Equatable, Sendable {
    public var base: String
    public var head: String
    public var files: [File]

    /// The change to one file. `status` is added, modified, deleted, or renamed.
    public struct File: Codable, Equatable, Sendable, Identifiable {
        public var path: String
        /// The path before a rename.
        public var oldPath: String? = nil
        public var status: String
        public var added: Int
        public var deleted: Int
        /// A binary file has no hunks.
        public var binary: Bool? = nil
        /// The file has more lines than the diff keeps. `added` and `deleted` count every line.
        public var truncated: Bool? = nil
        public var hunks: [Hunk]
        public var id: String { path }
        enum CodingKeys: String, CodingKey {
            case path, status, added, deleted, binary, truncated, hunks
            case oldPath = "old_path"
        }
    }

    /// One part of a file that changed, with lines of context.
    public struct Hunk: Codable, Equatable, Sendable {
        public var header: String
        public var oldStart: Int
        public var newStart: Int
        public var lines: [Line]
        enum CodingKeys: String, CodingKey {
            case header, lines
            case oldStart = "old_start", newStart = "new_start"
        }
    }

    /// One line of a hunk. A line that is only on one side has no number on the other.
    public struct Line: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case context, add, del }
        public var kind: Kind
        public var old: Int? = nil
        public var new: Int? = nil
        public var text: String
    }
}

extension RunDiff.Line {
    /// The leading spaces and tabs of the line, and the rest. The desk draws them apart, so a long line wraps under
    /// its code, not under its indent. A line of only spaces and tabs is all code.
    public var indentAndCode: (indent: String, code: String) {
        let indent = text.prefix { $0 == " " || $0 == "\t" }
        guard indent.count < text.count else { return ("", text) }
        return (String(indent), String(text.dropFirst(indent.count)))
    }
}

/// Output of `loam run tick` (ticket 206): the runs that the tick moved.
public struct RunTickResult: Codable, Equatable, Sendable {
    public var runs: [Run]
    public var warnings: [String]
}
