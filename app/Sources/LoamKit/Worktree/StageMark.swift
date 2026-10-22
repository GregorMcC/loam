import Foundation

/// The colour of a stage symbol, named by its token in `LoamTheme.colorTokens`
/// (docs/design, "Ship state"). A view maps it to the colour that follows the terminal theme.
public enum StageTone: String, Equatable, Sendable {
    case ink
    case inkMuted = "ink-muted"
    case inkFaint = "ink-faint"
    case rust
}

/// The stage table of the ship-state README: the symbol, the colour token and the name of each stage.
/// A view takes all three from here, so no symbol name or colour is copied into a view.
extension WorktreeStage {
    /// The SF Symbol. Nil for Not pushed, which keeps the ✎ mark (text, not a symbol), and for no stage.
    public var symbol: String? {
        switch self {
        case .merged: "arrow.triangle.merge"
        case .closed: "slash.circle"
        case .inMergeQueue: "list.number"
        case .conflicts: "exclamationmark.triangle"
        case .changesRequested: "text.bubble"
        case .checksFailed: "xmark.circle"
        case .approvalNeeded: "hand.raised"
        case .draft: "circle.dotted"
        case .behindBase: "arrow.down.circle"
        case .checksRunning: "circle.dashed"
        case .waitingForReview: "eye"
        case .blocked: "lock"
        case .readyToMerge: "checkmark.circle"
        case .pushedNoPR: "arrow.up.circle"
        case .notPushed, .noStage: nil
        }
    }

    /// Only Conflicts and Checks failed take `rust`. Ready to merge is `ink`. Merged, Closed, Draft and
    /// Pushed, no PR are `ink-faint`. Every other stage, and the ✎ of Not pushed, is `ink-muted`.
    public var tone: StageTone {
        switch self {
        case .conflicts, .checksFailed: .rust
        case .readyToMerge: .ink
        case .merged, .closed, .draft, .pushedNoPR: .inkFaint
        case .inMergeQueue, .changesRequested, .approvalNeeded, .behindBase, .checksRunning, .waitingForReview,
             .blocked, .notPushed, .noStage: .inkMuted
        }
    }

    /// The name of the stage, such as "Checks failed". Empty for no stage.
    public var words: String {
        switch self {
        case .merged: "Merged"
        case .closed: "Closed"
        case .inMergeQueue: "In merge queue"
        case .conflicts: "Conflicts"
        case .changesRequested: "Changes requested"
        case .checksFailed: "Checks failed"
        case .approvalNeeded: "Approval needed"
        case .draft: "Draft"
        case .behindBase: "Behind base"
        case .checksRunning: "Checks running"
        case .waitingForReview: "Waiting for review"
        case .blocked: "Blocked"
        case .readyToMerge: "Ready to merge"
        case .pushedNoPR: "Pushed, no PR"
        case .notPushed: "Not pushed"
        case .noStage: ""
        }
    }

    /// True for a stage that comes from a pull request. Pushed, no PR and Not pushed come from git,
    /// and no stage shows nothing.
    public var comesFromPullRequest: Bool {
        self != .pushedNoPR && self != .notPushed && self != .noStage
    }
}

/// The mark at the trailing edge of a worktree row in the sidebar (ticket 107). With a PR it is the
/// PR number and then the stage symbol. With no PR it is the ✎ mark for work that removal would lose.
/// A worktree with neither has no mark.
public struct StageMark: Equatable, Sendable {
    /// The stage that the symbol and the colour come from. `.notPushed` is the ✎ mark.
    public var stage: WorktreeStage
    /// The PR number. Nil for the ✎ mark.
    public var number: Int?
    /// The words for a tooltip: the PR number, then the status line of the Worktrees section, such as
    /// "#16 · 2 of 14 checks failed". `StatusLine` writes the line, so the two say the same. Nil for the
    /// ✎ mark, which has none.
    public var tooltip: String?
    /// The same words for VoiceOver and the driver, with commas.
    public var spoken: String

    /// The number as the row shows it, such as "#16". Nil for the ✎ mark.
    public var label: String? { number.map(Self.numberText) }
    public var symbol: String? { stage.symbol }
    public var tone: StageTone { stage.tone }

    /// The mark of a worktree. Nil when its folder is gone, and when it has nothing to show. `now` and
    /// `timeZone` give the day and the clock of a merge time in the status line.
    public init?(_ status: WorktreeStatus, now: Date = Date(), timeZone: TimeZone = .current) {
        guard !status.missing else { return nil }
        if let pr = status.pr, let stage = status.stage, stage.comesFromPullRequest {
            let line = StatusLine(of: status, now: now, timeZone: timeZone)
            let number = Self.numberText(pr.number)
            self.init(stage: stage, number: pr.number, tooltip: "\(number)\(StatusLine.separator)\(line.text)",
                      spoken: ([number] + line.parts.map(\.text)).joined(separator: ", "))
        } else if status.changed > 0 || status.unpushed > 0 {
            self.init(stage: .notPushed, number: nil, tooltip: nil, spoken: WorktreeStage.notPushed.words)
        } else {
            return nil
        }
    }

    private init(stage: WorktreeStage, number: Int?, tooltip: String?, spoken: String) {
        self.stage = stage
        self.number = number
        self.tooltip = tooltip
        self.spoken = spoken
    }

    private static func numberText(_ number: Int) -> String { "#\(number)" }
}
