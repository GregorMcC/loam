import Foundation

/// What the desk shows (ticket 207): one run that waits for you, its work, and your notes on it.
public struct DeskState: Equatable, Sendable {
    /// The run that the desk shows, or nil when nothing waits.
    public var runID: String?
    /// The work of the run, once the core has read it.
    public var diff: RunDiff?
    /// The path of the file that the diff shows.
    public var file: String?
    /// Your notes, by run, kept until you send them back.
    public var notes: [String: [DeskNote]] = [:]
    /// Keep the worktree after the merge.
    public var keepWorktree = false
    /// Why the last send-back or merge failed.
    public var error: String?
    /// A send-back, a merge, or an approval runs.
    public var busy = false
    /// Your edits of the drafts of runs in Shaping, by run, kept until you approve the run.
    public var shapeEdits: [String: ShapeEdit] = [:]
    /// The runs that Claude drafts again now.
    public var drafting: Set<String> = []

    public init() {}

    /// The notes on the run that the desk shows.
    public var currentNotes: [DeskNote] { runID.flatMap { notes[$0] } ?? [] }

    /// Your edits of the draft that the desk shows.
    public var currentEdit: ShapeEdit { runID.flatMap { shapeEdits[$0] } ?? ShapeEdit() }

    /// True when the last approval stopped at a new or changed setup command. The core names the command in
    /// `error`, and the next approval approves it.
    public var needsSetupApproval: Bool { error?.contains("--approve-setup") == true }
}

/// Your edits of the draft of a run in Shaping. Nil, or no answer, keeps what Claude drafted.
public struct ShapeEdit: Equatable, Sendable {
    public var goal: String?
    public var checks: [RunCheck]?
    /// What you want in place of an assumption, by its index.
    public var answers: [Int: String] = [:]

    public init() {}

    public var isEmpty: Bool { goal == nil && checks == nil && answers.isEmpty }
}

/// One note of yours on the work of a run: on a line of a file, or on the whole run.
public struct DeskNote: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var file: String?
    public var line: Int?
    public var text: String

    public init(id: UUID = UUID(), file: String?, line: Int?, text: String) {
        self.id = id
        self.file = file
        self.line = line
        self.text = text
    }

    /// The note as `loam run send-back --note` takes it: `<file>:<line>: <text>`, or the text alone.
    public var argument: String {
        guard let file, let line else { return text }
        return "\(file):\(line): \(text)"
    }
}
