import Foundation

/// The labels of the header of a pane in a split tab (spec 8.1, ticket 109): the pane title, then the
/// branch of its worktree, then the PR number, such as "native-panel" and "#16". The pane state has its
/// own place at the trailing edge, outside the room of these three.
public enum PaneHeaderLayout {
    public struct Widths: Equatable, Sendable {
        public var title: CGFloat
        public var branch: CGFloat
        public var number: CGFloat

        public init(title: CGFloat, branch: CGFloat, number: CGFloat) {
            self.title = title
            self.branch = branch
            self.number = number
        }
    }

    /// The room between the title and the branch.
    public static let gap: CGFloat = 8
    /// The room between the labels of the branch and the PR number. None: the insets of the two label cells
    /// already make about one space of the caption face, as in "native-panel #16".
    public static let numberGap: CGFloat = 0

    /// The width of each label in `room`, from the width that each one needs (0 for no PR number). The PR
    /// number is never cut. The title keeps its width in the room that is left, and the branch takes the
    /// rest, so a long branch is cut first.
    public static func widths(title: CGFloat, branch: CGFloat, number: CGFloat, room: CGFloat) -> Widths {
        let numberRoom = number > 0 ? number + numberGap : 0
        let titleWidth = min(title, max(0, room - numberRoom))
        let branchWidth = min(branch, max(0, room - titleWidth - gap - numberRoom))
        return Widths(title: titleWidth, branch: branchWidth, number: number)
    }
}
