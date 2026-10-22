import Foundation

/// The button of the PR popover that does the main job of a stage (ticket 109). The stage decides it
/// (`init(stage:)`): Land… at Ready to merge, and Send failures, Send review or Send conflicts to session
/// where a session can fix the problem. Every other stage has none.
public enum PRPrimaryAction: String, CaseIterable, Sendable {
    case land
    case sendFailures = "send-failures"
    case sendReview = "send-review"
    case sendConflicts = "send-conflicts"

    public init?(stage: WorktreeStage) {
        switch stage {
        case .readyToMerge: self = .land
        case .checksFailed: self = .sendFailures
        case .changesRequested: self = .sendReview
        case .conflicts: self = .sendConflicts
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .land: "Land\u{2026}"
        case .sendFailures: "Send failures to session"
        case .sendReview: "Send review to session"
        case .sendConflicts: "Send conflicts to session"
        }
    }

    /// The buttons whose ticket is merged. The popover shows a primary button only when it is in this set,
    /// so a later ticket adds its case here when it builds the button: Land… is ticket 112, and the three
    /// Send buttons are ticket 110.
    public static let built: Set<PRPrimaryAction> = []
}

/// The smaller buttons of the PR popover. The popover shows each one only when it can do something.
public enum PRSecondaryAction: String, CaseIterable, Sendable {
    /// `loam worktree rerun`.
    case rerunFailed = "rerun-failed"
    /// `loam worktree update`.
    case updateBranch = "update-branch"
    case openOnGitHub = "open-on-github"
    case copyBranchName = "copy-branch-name"

    public var title: String {
        switch self {
        case .rerunFailed: "Re-run failed"
        case .updateBranch: "Update branch"
        case .openOnGitHub: "Open on GitHub"
        case .copyBranchName: "Copy branch name"
        }
    }
}

/// What the PR popover says for one worktree (ticket 109): a pure function of the row that the core
/// gave, so tests cover every stage. The view only draws it. The words of the rows come from `StatusLine`,
/// so the sidebar tooltip, the Worktrees section and the popover say the same.
///
/// A worktree with a PR shows the stage, the title, four rows (Checks, Review, Base and Conflicts), the
/// failed checks and the buttons. A merged or closed PR shows one State row. A worktree with no PR shows
/// its base and its local state (board 5.3).
public struct PRPopoverContent: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var label: String
        public var parts: [StatusLine.Part]
        /// True for a value that is code, such as a base branch. The view sets it in the mono face.
        public var isCode = false
    }

    /// A failed check, with its time and the page of its log.
    public struct FailedCheckRow: Equatable, Sendable {
        public var name: String
        /// "3:10". Nil when GitHub gives no run time.
        public var duration: String?
        /// The page of the check. Nil when the core gives none or it is not an https address.
        public var log: URL?
    }

    /// The stage in the header. Nil for a worktree with no PR, which has no header.
    public let stage: WorktreeStage?
    public let hasPullRequest: Bool
    /// "Updated 18:14", the time of the last answer of GitHub. Nil with no PR, and when GitHub never answered.
    public let updated: String?
    /// "#142 Link labels from plot brief", or the branch when there is no PR.
    public let title: String
    /// "link-labels → main · 9 commits", or why there is no PR.
    public let subtitle: String
    public let rows: [Row]
    public let failedChecks: [FailedCheckRow]
    /// A line under the rows for a stage that the rows do not explain: Blocked and In merge queue.
    public let stageNote: String?
    /// The line for a refresh that failed, or for a repo with no GitHub remote.
    public let notice: String?
    /// The primary button. Nil for a stage with none, and for a button that no ticket has built.
    public let primary: PRPrimaryAction?
    public let secondary: [PRSecondaryAction]
    /// What Open on GitHub opens: the PR, or the compare page of a pushed branch.
    public let githubPage: URL?

    /// `attemptedAt` is the time of the last refresh that the app asked for, which the offline line names.
    /// `now` and `timeZone` give the day and the clock of the times. `built` is the set of primary buttons
    /// that exist.
    public init(_ status: WorktreeStatus, attemptedAt: Date? = nil, now: Date = Date(), timeZone: TimeZone = .current,
                built: Set<PRPrimaryAction> = PRPrimaryAction.built) {
        func clock(_ date: Date) -> String { ChangeRules.stamp(date, now: now, timeZone: timeZone) }
        let line = StatusLine(of: status, now: now, timeZone: timeZone)
        let answered = status.prCheckedAt.flatMap(ChangeRules.date)
        let note = Self.notice(for: status, attemptedAt: attemptedAt.map(clock), answeredAt: answered.map(clock))
        if let pr = status.pr, let stage = status.stage, stage.comesFromPullRequest {
            self.stage = stage
            hasPullRequest = true
            updated = answered.map { "Updated \(clock($0))" }
            title = "\(StageMark.numberText(pr.number)) \(pr.title)"
            subtitle = Self.subtitle(of: pr)
            let open = pr.state == Self.openState
            rows = open
                ? [Row(label: "Checks", parts: StatusLine.checks(of: pr)), Row(label: "Review", parts: StatusLine.review(of: pr)),
                   Row(label: "Base", parts: StatusLine.base(of: pr)), Row(label: "Conflicts", parts: StatusLine.conflicts(of: pr))]
                : [Row(label: "State", parts: line.parts)]
            failedChecks = open ? pr.failedChecks.map(Self.row(of:)) : []
            stageNote = Self.stageNote(for: stage, line: line)
            primary = PRPrimaryAction(stage: stage).flatMap { built.contains($0) ? $0 : nil }
            githubPage = status.pullRequestPage
            var buttons: [PRSecondaryAction] = []
            if open, pr.failedChecks.contains(where: { $0.runID != nil }) { buttons.append(.rerunFailed) }
            if open, pr.behindBase > 0, stage != .inMergeQueue { buttons.append(.updateBranch) }
            if githubPage != nil { buttons.append(.openOnGitHub) }
            secondary = buttons
        } else {
            stage = nil
            hasPullRequest = false
            updated = nil
            title = status.worktree.branch
            subtitle = status.missing ? line.text : "No pull request yet"
            // A worktree that started on an existing branch has no base. A gone folder has no local state.
            var local: [Row] = []
            if !status.worktree.base.isEmpty {
                local.append(Row(label: "Base", parts: [StatusLine.Part(text: status.worktree.base)], isCode: true))
            }
            if !status.missing { local.append(Row(label: "Local", parts: line.parts)) }
            rows = local
            failedChecks = []
            stageNote = nil
            primary = nil
            githubPage = status.compareURL.flatMap(Self.httpsURL)
            secondary = (githubPage == nil ? [] : [.openOnGitHub]) + [.copyBranchName]
        }
        notice = note
    }

    // MARK: Words

    private static let openState = "OPEN"

    /// "link-labels → main · 9 commits".
    private static func subtitle(of pr: PullRequest) -> String {
        var words = ["\(pr.head) \u{2192} \(pr.base)"]
        if pr.commits > 0 { words.append("\(pr.commits) \(pr.commits == 1 ? "commit" : "commits")") }
        return words.joined(separator: StatusLine.separator)
    }

    /// Blocked sends you to GitHub, and the merge queue gives a place. The other stages explain themselves
    /// in the rows.
    private static func stageNote(for stage: WorktreeStage, line: StatusLine) -> String? {
        switch stage {
        case .blocked: "\(line.text). Open it on GitHub to see why."
        case .inMergeQueue: "\(line.text)."
        default: nil
        }
    }

    /// "Loam could not reach GitHub at 18:14. This is the state from 18:02." The attempt time is left out
    /// when the app has not asked yet, and the old state when GitHub never answered. Nil for a note that
    /// the Worktrees section already shows as a callout (`gh` missing, signed out, no access).
    private static func notice(for status: WorktreeStatus, attemptedAt: String?, answeredAt: String?) -> String? {
        switch status.prNote {
        case .noGitHubRemote:
            return "This repo has no GitHub remote."
        case .offline, .rateLimited:
            let first = "Loam could not reach GitHub" + (attemptedAt.map { " at \($0)" } ?? "") + "."
            return answeredAt.map { first + " This is the state from \($0)." } ?? first
        default:
            return nil
        }
    }

    // MARK: Checks

    private static func row(of check: FailedCheck) -> FailedCheckRow {
        FailedCheckRow(name: check.name, duration: duration(check.duration), log: httpsURL(check.url))
    }

    /// "0:42", "3:10" or "1:02:05". Nil for zero, which is GitHub saying that it has no run time.
    private static func duration(_ seconds: Int) -> String? {
        guard seconds > 0 else { return nil }
        let (minutes, rest) = (seconds / 60, seconds % 60)
        guard minutes >= 60 else { return String(format: "%d:%02d", minutes, rest) }
        return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, rest)
    }

    /// An address from the core opens only when it is https.
    private static func httpsURL(_ text: String) -> URL? {
        URL(string: text).flatMap { $0.scheme == "https" ? $0 : nil }
    }
}
