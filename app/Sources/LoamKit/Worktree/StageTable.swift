import Foundation

/// The colour of a stage symbol, as a design token. A view maps it to a colour, so no colour is
/// copied into a view. Only Conflicts and Checks failed take `rust` (ADR 0007).
public enum StageTone: Equatable, Sendable {
    case ink, inkMuted, inkFaint, rust
}

/// The mark of a stage: an SF Symbol, or a text mark.
public enum StageGlyph: Equatable, Sendable {
    case symbol(String)
    case text(String)
}

/// The stage table of the ship state (ADR 0007, ticket 108): the mark, the colour, and the name of
/// each stage. The core decides the stage. The views read this table, so the sidebar, the plot panel
/// and the pull request popover show a stage in the same way.
extension WorktreeStage {
    /// The mark of the stage. Nil for `.noStage`, which shows nothing.
    public var glyph: StageGlyph? {
        switch self {
        case .merged: .symbol("arrow.triangle.merge")
        case .closed: .symbol("slash.circle")
        case .inMergeQueue: .symbol("list.number")
        case .conflicts: .symbol("exclamationmark.triangle")
        case .changesRequested: .symbol("text.bubble")
        case .checksFailed: .symbol("xmark.circle")
        case .approvalNeeded: .symbol("hand.raised")
        case .draft: .symbol("circle.dotted")
        case .behindBase: .symbol("arrow.down.circle")
        case .checksRunning: .symbol("circle.dashed")
        case .waitingForReview: .symbol("eye")
        case .blocked: .symbol("lock")
        case .readyToMerge: .symbol("checkmark.circle")
        case .pushedNoPR: .symbol("arrow.up.circle")
        // The mark that the sidebar shows for work that removal would lose.
        case .notPushed: .text("\u{270E}")
        case .noStage: nil
        }
    }

    /// The colour of the mark. A stage that is done or quiet is `ink-faint`, Ready to merge is `ink`.
    public var tone: StageTone {
        switch self {
        case .conflicts, .checksFailed: .rust
        case .readyToMerge: .ink
        case .merged, .closed, .draft, .pushedNoPR, .noStage: .inkFaint
        case .inMergeQueue, .changesRequested, .approvalNeeded, .behindBase, .checksRunning, .waitingForReview,
             .blocked, .notPushed: .inkMuted
        }
    }

    /// The name of the stage, as a tooltip says it: "Checks failed".
    public var title: String {
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
}
