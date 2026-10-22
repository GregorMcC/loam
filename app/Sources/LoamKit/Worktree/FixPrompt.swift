import Foundation

/// The prompt that Send to session types into the session of a worktree (ticket 110), one for each stage that a
/// session can fix. It names the `gh` command that shows the details, and the session reads them itself: Loam never
/// copies the text of a log or a comment into it (ADR 0001, ADR 0007). Each prompt is one line, because `PaneText`
/// refuses text with a line break inside it.
public struct FixPrompt: Equatable, Sendable {
    /// What the session fixes. The raw value is the word for it in the toast and the footnote of the popover, as in
    /// "Loam typed the failures into ✳ Native panel spacing."
    public enum Kind: String, CaseIterable, Sendable {
        case failures
        case review
        case conflicts

        /// The kind for a stage. Nil for a stage that no prompt fixes.
        public init?(stage: WorktreeStage) {
            switch stage {
            case .checksFailed: self = .failures
            case .changesRequested: self = .review
            case .conflicts: self = .conflicts
            default: return nil
            }
        }

        /// The primary button of the PR popover for this kind, such as "Send failures to session".
        public var action: PRPrimaryAction {
            switch self {
            case .failures: .sendFailures
            case .review: .sendReview
            case .conflicts: .sendConflicts
            }
        }
    }

    /// The most failed checks that a prompt names. "and 3 more" counts the rest.
    public static let namedChecks = 5
    /// The most characters of a check name in a prompt, with the "…" at the end of a name that is cut.
    public static let longestCheckName = 80

    public let kind: Kind
    public let text: String

    /// The prompt for the stage of a worktree, from its PR. Nil for a stage that no prompt fixes, and for a worktree
    /// with no PR.
    public init?(_ status: WorktreeStatus) {
        guard let stage = status.stage, let kind = Kind(stage: stage), let pr = status.pr else { return nil }
        self.init(kind, pr: pr)
    }

    public init(_ kind: Kind, pr: PullRequest) {
        self.kind = kind
        let number = pr.number
        switch kind {
        case .failures:
            let names = pr.failedChecks.map { Self.cut(Self.oneLine($0.name)) }
            var list = names.prefix(Self.namedChecks).joined(separator: ", ")
            if names.count > Self.namedChecks { list += ", and \(names.count - Self.namedChecks) more" }
            let failed = list.isEmpty ? "Checks failed on #\(number)." : "Checks failed on #\(number): \(list)."
            text = "\(failed) Run `gh pr checks \(number)`, read the failing logs, fix them, and push."
        case .review:
            let comments = pr.comments == 0 ? "" : ", with \(pr.comments) review \(pr.comments == 1 ? "comment" : "comments")"
            text = "PR #\(number) has changes requested\(comments). Run `gh pr view \(number) --comments`, address each comment, and push."
        case .conflicts:
            let (base, head) = (Self.oneLine(pr.base), Self.oneLine(pr.head))
            text = "PR #\(number) conflicts with \(base). Merge origin/\(base) into \(head), resolve the conflicts, run the tests, and push."
        }
    }

    /// The text as one line that shows each character it has. GitHub gives the names, and a PR from a fork can name
    /// its own checks and branches. A control character could act as a key in the terminal, and a line break as
    /// Return. A character that shows nothing could hide words: a direction mark, a zero-width or tag character, a
    /// byte order mark, a private use or an unassigned code point. So each run of white space and control characters
    /// becomes one space, and the format, private use, unassigned and surrogate code points go.
    static func oneLine(_ text: String) -> String {
        let shown = text.unicodeScalars.filter { !hidden.contains($0.properties.generalCategory) }
        return shown
            .split { $0.properties.generalCategory == .control || $0.properties.isWhitespace }
            .map { String(String.UnicodeScalarView($0)) }
            .joined(separator: " ")
    }

    /// The general categories that show nothing: Cf, Co, Cn and Cs. Cf has the direction marks.
    private static let hidden: Set<Unicode.GeneralCategory> = [.format, .privateUse, .unassigned, .surrogate]

    /// A check name of at most `longestCheckName` characters. A longer name ends in "…".
    static func cut(_ name: String) -> String {
        name.count > longestCheckName ? String(name.prefix(longestCheckName - 1)) + "\u{2026}" : name
    }
}
