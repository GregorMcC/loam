import Foundation

/// The second line of a worktree row in the plot panel (ticket 108): what the stage means, in a few
/// words, such as "2 of 14 checks failed · 3 behind main". Simplified Technical English. It reads
/// the stage and the PR that the core gives (docs/contract.md, "Ship state of worktrees"). With no PR
/// it is the local state: "2 changed", "4 commits not pushed", or "Pushed, no PR".
///
/// The line is a list of parts, so a view can set the failing words in `rust` and the rest in
/// `ink-muted`. Only Conflicts and Checks failed fail (ADR 0007).
public struct StatusLine: Equatable, Sendable {
    public struct Part: Equatable, Sendable {
        public var text: String
        /// True for the words that name a failure. Only these take `rust`.
        public var failing: Bool

        public init(text: String, failing: Bool = false) {
            self.text = text
            self.failing = failing
        }
    }

    public let parts: [Part]

    /// What stands between the parts of a line.
    public static let separator = " \u{00B7} "

    /// The parts as one line, with `separator` between them.
    public var text: String { parts.map(\.text).joined(separator: Self.separator) }

    /// `now` and `timeZone` give the day and the clock of a merge time.
    public init(of status: WorktreeStatus, now: Date = Date(), timeZone: TimeZone = .current) {
        if status.missing {
            parts = [Part(text: "Folder is gone")]
        } else if let pr = status.pr, let stage = status.stage, stage != .noStage {
            parts = Self.parts(of: pr, stage: stage, now: now, timeZone: timeZone)
        } else {
            parts = Self.localParts(of: status)
        }
    }

    // MARK: A PR

    private static func parts(of pr: PullRequest, stage: WorktreeStage, now: Date, timeZone: TimeZone) -> [Part] {
        let checks = pr.checks
        var parts: [Part]
        switch stage {
        case .merged:
            parts = [plain(pr.mergedAt.map { "Merged \(ChangeRules.stamp($0, now: now, timeZone: timeZone))" } ?? "Merged")]
        case .closed:
            parts = [plain("Closed without a merge")]
        case .inMergeQueue:
            parts = [plain("Position \(pr.queuePosition) in the merge queue")]
        case .conflicts:
            parts = [Part(text: "Conflicts with \(pr.base)", failing: true)]
        case .changesRequested:
            parts = [plain("Changes requested")] + (pr.comments > 0 ? [plain(count(pr.comments, "comment"))] : [])
        case .checksFailed:
            // The stage needs a failed check, so a PR with no checks cannot come from the core.
            parts = [Part(text: checks.total > 0 ? progress(checks.failed, of: checks.total, "failed") : "Checks failed", failing: true)]
        case .approvalNeeded:
            parts = [plain(waitingText(checks.waiting))]
        case .draft:
            parts = [plain("Draft")] + (checks.total > 0 ? [plain(progress(done(checks), of: checks.total, "done"))] : [])
        case .behindBase:
            parts = [plain(pr.behindBase > 0 ? "\(count(pr.behindBase, "commit")) behind \(pr.base)" : "Behind \(pr.base)")]
        case .checksRunning:
            parts = [plain(runningText(checks))]
        case .waitingForReview:
            // GitHub gives no count of the approvals that a merge needs, so the line cannot say it.
            parts = [plain("Review required")] + (pr.approvals > 0 ? [plain(count(pr.approvals, "approval"))] : [])
        case .blocked:
            parts = [plain("GitHub blocks the merge")]
        case .readyToMerge:
            parts = readyParts(of: pr)
        case .pushedNoPR, .notPushed, .noStage:
            parts = []
        }
        if pr.state == "OPEN", pr.behindBase > 0, stage != .behindBase, stage != .inMergeQueue {
            parts.append(plain("\(pr.behindBase) behind \(pr.base)"))
        }
        return parts
    }

    /// "14 of 14 checks passed · Approved". When only optional checks failed (`UNSTABLE`), GitHub
    /// allows the merge, and the line says "14 of 14 required checks passed · 2 optional failed".
    private static func readyParts(of pr: PullRequest) -> [Part] {
        let checks = pr.checks
        let optionalFailed = pr.failedChecks.filter { !$0.required }.count
        if pr.mergeState == "UNSTABLE", optionalFailed > 0, let required = checks.required, required > 0 {
            let noun = required == 1 ? "check" : "checks"
            return [plain("\(checks.requiredPassed ?? 0) of \(required) required \(noun) passed"),
                    plain("\(optionalFailed) optional failed")]
        }
        var parts: [Part] = []
        if checks.total > 0 { parts.append(plain(progress(checks.passed, of: checks.total, "passed"))) }
        if pr.reviewDecision == "APPROVED" { parts.append(plain("Approved")) }
        return parts.isEmpty ? [plain("Ready to merge")] : parts
    }

    /// The summaries of GitHub for checks that have not finished.
    private static let activeCheckStates: Set<String> = ["PENDING", "EXPECTED"]

    /// The values of `mergeable` and `merge_state` that name a conflict, and the wait of GitHub.
    private static let conflictingState = "CONFLICTING"
    private static let dirtyState = "DIRTY"
    private static let unknownState = "UNKNOWN"

    /// Checks running, or "Checking…" when GitHub has not finished its merge check (mergeable UNKNOWN).
    /// The core gives the stage then, and the row has no check that runs or waits and no unfinished
    /// summary (README, "Stages"). The sidebar tooltip reads this line too (`StageMark`).
    private static func runningText(_ checks: PRCheckCounts) -> String {
        let pending = checks.running > 0 || checks.waiting > 0 || activeCheckStates.contains(checks.state)
        guard pending else { return "Checking\u{2026}" }
        return checks.total > 0 ? progress(done(checks), of: checks.total, "done") : "Waiting for checks"
    }

    /// "1 workflow waits for approval".
    private static func waitingText(_ number: Int) -> String {
        number == 1 ? "1 workflow waits for approval" : "\(number) workflows wait for approval"
    }

    /// The checks that neither run nor wait. A cancelled or stale check counts as done.
    private static func done(_ checks: PRCheckCounts) -> Int {
        max(checks.total - checks.running - checks.waiting, 0)
    }

    // MARK: No PR

    private static func localParts(of status: WorktreeStatus) -> [Part] {
        var parts: [Part] = []
        if status.stage == .pushedNoPR { parts.append(plain("Pushed, no PR")) }
        if status.changed > 0 { parts.append(plain("\(status.changed) changed")) }
        if status.unpushed > 0 { parts.append(plain("\(count(status.unpushed, "commit")) not pushed")) }
        return parts.isEmpty ? [plain("No changes")] : parts
    }

    // MARK: Words

    private static func plain(_ text: String) -> Part { Part(text: text) }

    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    /// "2 of 14 checks failed". The noun agrees with the total.
    private static func progress(_ number: Int, of total: Int, _ verb: String) -> String {
        "\(number) of \(total) \(total == 1 ? "check" : "checks") \(verb)"
    }
}

// MARK: The rows of the PR popover (ticket 109)

/// One short phrase for each row of the popover: Checks, Review, Base and Conflicts. They are parts, so
/// the failing words take `rust` as in the status line. They are phrases of an open PR.
extension StatusLine {
    /// "2 failed · 12 passed". Checks that run say how many are done: "9 of 14 done". The count of the
    /// failed checks says "optional" when the base branch does not need them, so it does not fail.
    public static func checks(of pr: PullRequest) -> [Part] {
        let checks = pr.checks
        guard checks.total > 0 else { return [plain(activeCheckStates.contains(checks.state) ? "Waiting for checks" : "No checks")] }
        let unfinished = checks.running > 0 || checks.waiting > 0
        var parts: [Part] = []
        if checks.failed > 0 {
            // A check that the merge needs fails the row. With no required check, any failed check counts.
            let needed = pr.failedChecks.contains(where: \.required) || (checks.required ?? 0) == 0
            parts.append(Part(text: needed ? "\(checks.failed) failed" : "\(checks.failed) optional failed", failing: needed))
            if checks.passed > 0 { parts.append(plain(passed(checks.passed))) }
            if checks.running > 0 { parts.append(plain("\(checks.running) running")) }
        } else if unfinished {
            parts.append(plain("\(done(checks)) of \(checks.total) done"))
        } else {
            parts.append(plain("\(checks.passed) of \(checks.total) passed"))
        }
        if checks.waiting > 0 { parts.append(plain(waitingText(checks.waiting))) }
        return parts
    }

    /// "12 passed". The Checks row and the row that opens the passed checks say it the same way.
    public static func passed(_ count: Int) -> String { "\(count) passed" }

    /// "Approved · 1 approval", "Changes requested · 3 comments", "Review required", or "No review
    /// required". GitHub gives no count of the approvals that a merge needs, so the phrase counts the
    /// approvals made.
    public static func review(of pr: PullRequest) -> [Part] {
        let approvals = pr.approvals > 0 ? [plain(count(pr.approvals, "approval"))] : []
        switch pr.reviewDecision {
        case "APPROVED": return [plain("Approved")] + approvals
        case "CHANGES_REQUESTED": return [plain("Changes requested")] + (pr.comments > 0 ? [plain(count(pr.comments, "comment"))] : [])
        case "REVIEW_REQUIRED": return [plain("Review required")] + approvals
        default: return approvals.isEmpty ? [plain("No review required")] : [plain("Approved")] + approvals
        }
    }

    /// "3 commits behind main", or "Up to date with main".
    public static func base(of pr: PullRequest) -> [Part] {
        [plain(pr.behindBase > 0 ? "\(count(pr.behindBase, "commit")) behind \(pr.base)" : "Up to date with \(pr.base)")]
    }

    /// "Conflicts with main" fails. "Checking…" is GitHub still working it out, which is no failure.
    public static func conflicts(of pr: PullRequest) -> [Part] {
        if pr.mergeable == conflictingState || pr.mergeState == dirtyState {
            return [Part(text: "Conflicts with \(pr.base)", failing: true)]
        }
        return [plain(pr.mergeable == unknownState ? "Checking\u{2026}" : "None")]
    }
}
