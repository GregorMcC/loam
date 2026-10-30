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
    /// Move the Linear issue to Done at the merge. Nil follows the Done switch of the Linear updates.
    public var linearDone: Bool?
    /// Move Where it stands of the plot on to the text of the ship notes at the merge.
    public var moveWhereItStands = true
    /// The run limits, read for a run in Shaping. Nil before the read, or when it failed.
    public var limits: RunLimits?
    /// The switches of the updates to Linear, read for a run from Linear. Nil before the read, or when it failed.
    public var linearUpdates: LinearUpdates?
    /// The setup command of the repo of the run in Shaping, or nil when the repo has none. An approval approves it.
    public var setup: String?
    /// The title of the recurring run that shaped the run in Shaping, or nil.
    public var recurringTitle: String?
    /// The review of the PR of the run that the desk shows, when the run is ready with a PR (TAS-61). Nil before the
    /// read, and when it failed.
    public var review: DeskReview?
    /// Why the core could not read the review, such as gh signed out.
    public var reviewError: String?
    /// The `updated_at` of the run when the desk read its review. The review is read again when the run changes.
    public var reviewStamp: String?
    /// The review row shows its comments. It starts closed, so a long review does not push Merge down.
    public var reviewOpen = false
    /// Why the last send-back or merge failed.
    public var error: String?
    /// A send-back, a merge, or an approval runs.
    public var busy = false
    /// Your edits of the drafts of runs in Shaping, by run, kept until you approve the run.
    public var shapeEdits: [String: ShapeEdit] = [:]
    /// The runs that Claude drafts again now.
    public var drafting: Set<String> = []
    /// The rules of the plot of the run in Shaping that the desk shows (ticket 209). The gate runs them after the
    /// checks of the draft.
    public var rules: [Rule] = []
    /// The rule that Loam offers after a send-back, until you add it or say not now. It stays while you move
    /// through the queue.
    public var ruleOffer: DeskRuleOffer?

    public init() {}

    /// The notes on the run that the desk shows.
    public var currentNotes: [DeskNote] { runID.flatMap { notes[$0] } ?? [] }

    /// Your edits of the draft that the desk shows.
    public var currentEdit: ShapeEdit { runID.flatMap { shapeEdits[$0] } ?? ShapeEdit() }

    /// True when the last approval stopped at a new or changed setup command. The core names the command in
    /// `error`, and the next approval approves it.
    public var needsSetupApproval: Bool { error?.contains("--approve-setup") == true }
}

/// A rule that Loam offers after a send-back (ticket 209): a note that you sent back on two runs of the plot.
public struct DeskRuleOffer: Equatable, Sendable {
    public var plotID: String
    public var offer: RuleOffer
    /// Why the last Add rule failed.
    public var error: String?

    public init(plotID: String, offer: RuleOffer) {
        self.plotID = plotID
        self.offer = offer
    }
}

/// Your edits of the draft of a run in Shaping. Nil, or no answer, keeps what Claude drafted.
public struct ShapeEdit: Equatable, Sendable {
    public var goal: String?
    public var checks: [RunCheck]?
    /// What you want in place of an assumption, by its index.
    public var answers: [Int: String] = [:]
    /// The follow-ups that you dropped, by index. Loam files each other follow-up as an issue.
    public var droppedFollowUps: Set<Int> = []

    public init() {}

    public var isEmpty: Bool { goal == nil && checks == nil && answers.isEmpty && droppedFollowUps.isEmpty }
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
