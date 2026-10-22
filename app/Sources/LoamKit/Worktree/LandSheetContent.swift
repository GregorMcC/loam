import Foundation

extension MergeMethod {
    /// The words of the segmented control of the Land sheet.
    public var title: String {
        switch self {
        case .merge: "Merge commit"
        case .squash: "Squash"
        case .rebase: "Rebase"
        }
    }
}

/// What the Land sheet says for a dry run of `loam worktree land` (ticket 112): a pure function of the plan that the
/// core gave, so tests cover every state. The view only draws it. The merge cannot be undone, so every check that
/// the core runs shows as a row before you press Merge, and the primary button is off while any row blocks. The
/// words of the rows follow board 3.1 and 3.2 of the ship-state design.
public struct LandSheetContent: Equatable, Sendable {
    /// How a row looks. A blocking row takes the `rust` symbol, a note row the muted one.
    public enum Tone: Equatable, Sendable {
        case good
        /// Not good, and no reason to stop: a check that still runs, a branch that is behind.
        case note
        case blocking
    }

    /// The button at the end of a row.
    public enum RowAction: Equatable, Sendable {
        /// Send to session (ticket 110) for the kind of problem that the row shows.
        case send(FixPrompt.Kind)
        /// `loam worktree update`.
        case updateBranch
        case openOnGitHub

        public var title: String {
            switch self {
            case .send(let kind): kind.action.title
            case .updateBranch: PRSecondaryAction.updateBranch.title
            case .openOnGitHub: PRSecondaryAction.openOnGitHub.title
            }
        }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        /// The check: checks, review, behind_base, conflicts, github, or worktree (the two local checks as one).
        public var id: String
        public var tone: Tone
        /// An SF Symbol name.
        public var symbol: String
        public var title: String
        /// "14 of 14", "2 changed · 0 not pushed". Empty when the row has none.
        public var value: String
        public var action: RowAction?
        /// What to do, in `rust`, for a blocking row that no button fixes.
        public var hint: String?

        /// True when the row has something at its trailing edge, so its value stands next to the title.
        public var hasTrailing: Bool { action != nil || hint != nil }
    }

    /// The button that merges.
    public enum Primary: Equatable, Sendable {
        /// `land` with the method, now.
        case merge
        /// `land --auto`: GitHub merges when the checks pass.
        case mergeWhenReady
        case addToMergeQueue
    }

    /// "Land #142 Link labels from plot brief".
    public let title: String
    /// "link-labels → main · 9 commits".
    public let subtitle: String
    public let rows: [Row]
    public let primary: Primary
    public let primaryTitle: String
    /// False while any row blocks, and for a PR that is merged already.
    public let canMerge: Bool
    public let blockingCount: Int
    /// The line left of the buttons.
    public let footer: String
    /// The methods that the repo allows, and that this app knows. Empty for a merge queue, which takes none.
    public let mergeMethods: [MergeMethod]
    /// The method that the control starts on.
    public let defaultMethod: MergeMethod?
    public let mergeQueue: Bool
    /// The PR is merged already, such as when it merged between the click on Land… and the plan.
    public let isMerged: Bool
    /// "Close its 2 panes and remove the worktree". The view sets the name of the worktree after it, in the mono face.
    public let removeLabel: String
    public let worktreeName: String
    /// Under "After the merge", for a merge that waits for GitHub. Nil for a merge now.
    public let afterNote: String?
    public let number: Int
    public let prTitle: String

    /// `land --auto`.
    public var usesAuto: Bool { primary == .mergeWhenReady }

    /// True when Loam can save Where it stands at the merge. A merge that waits for GitHub is not a merge yet, and
    /// the core records no Where it stands text for it.
    public var canMoveWhereItStandsOn: Bool { !usesAuto && !mergeQueue && !isMerged }

    /// `openPanes` are the panes that run in the worktree now.
    public init(_ plan: LandResult, openPanes: Int) {
        let pr = plan.pr
        number = pr.number
        prTitle = FixPrompt.oneLine(pr.title)
        title = Self.title(of: pr)
        subtitle = Self.subtitle(of: pr)
        isMerged = plan.merged || pr.state == "MERGED"
        mergeQueue = plan.mergeQueue && !isMerged
        worktreeName = plan.worktree.name
        removeLabel = switch openPanes {
        case 0: "Remove the worktree"
        case 1: "Close its pane and remove the worktree"
        default: "Close its \(openPanes) panes and remove the worktree"
        }

        // The methods that this app knows. A merge queue takes none.
        let methods = mergeQueue || isMerged ? [] : plan.methods.compactMap(MergeMethod.init(rawValue:))
        mergeMethods = methods
        defaultMethod = MergeMethod(rawValue: plan.defaultMethod).flatMap { methods.contains($0) ? $0 : nil } ?? methods.first

        let rows = isMerged ? [] : Self.rows(of: plan)
        self.rows = rows
        blockingCount = rows.filter { $0.tone == .blocking }.count
        let waiting = !mergeQueue && plan.checks.contains { $0.name == "checks" && ($0.state == "running" || $0.state == "waiting") }
        primary = mergeQueue ? .addToMergeQueue : waiting ? .mergeWhenReady : .merge
        primaryTitle = switch primary {
        case .merge: "Merge \(StageMark.numberText(pr.number))"
        case .mergeWhenReady: "Merge when ready"
        case .addToMergeQueue: "Add to merge queue"
        }
        // The core's word decides, and the rows only explain it: a plan where `ready` is false never merges.
        canMerge = !isMerged && plan.ready && blockingCount == 0
        afterNote = !isMerged && (mergeQueue || waiting) ? "Loam does this when GitHub has merged the pull request." : nil

        let numberText = StageMark.numberText(pr.number)
        footer = if isMerged {
            "\(numberText) is merged on GitHub already."
        } else if blockingCount > 0 || !plan.ready {
            blockingCount == 1 ? "Fix the item in rust before you merge." : "Fix the \(max(blockingCount, 2)) items in rust before you merge."
        } else if mergeQueue {
            "The queue merges \(numberText) after its checks pass on \(pr.base)."
        } else if waiting {
            "GitHub merges \(numberText) when its checks pass. Loam tidies up after the merge."
        } else {
            "You cannot undo a merge."
        }
    }

    /// "Land #142 Link labels from plot brief". The sheet shows it from the row of the worktree while the plan loads.
    public static func title(of pr: PullRequest) -> String {
        "Land \(StageMark.numberText(pr.number)) \(FixPrompt.oneLine(pr.title))"
    }

    /// "link-labels → main · 9 commits", the line under the title.
    public static func subtitle(of pr: PullRequest) -> String { PRPopoverContent.subtitle(of: pr) }

    // MARK: Rows

    /// The rows in the order of the core. The two local checks make one row. A GitHub check that is clear has no row.
    private static func rows(of plan: LandResult) -> [Row] {
        let pr = plan.pr
        let kind = FixPrompt.Kind(stage: plan.stage)
        func check(_ name: String) -> LandCheck? { plan.checks.first { $0.name == name } }
        var rows: [Row] = []
        if let c = check("checks") { rows.append(checks(c, pr: pr, kind: kind)) }
        if let c = check("review") { rows.append(review(c, pr: pr, kind: kind)) }
        if let c = check("behind_base") { rows.append(behind(c, pr: pr)) }
        if let c = check("conflicts") { rows.append(conflicts(c, pr: pr, kind: kind)) }
        if let c = check("github"), c.state != "clear" { rows.append(github(c)) }
        if check("local_changes") != nil || check("unpushed_commits") != nil {
            rows.append(local(plan, changes: check("local_changes"), unpushed: check("unpushed_commits")))
        }
        return rows
    }

    /// A button for a problem that a session can fix, when the stage of the worktree gives that very prompt. The
    /// stage order puts Changes requested and Conflicts before Checks failed, so a worktree with two problems
    /// types the prompt of the first, and the other rows get a hint.
    private static func fix(_ wanted: FixPrompt.Kind, _ stage: FixPrompt.Kind?, hint: String) -> (RowAction?, String?) {
        stage == wanted ? (.send(wanted), nil) : (nil, hint)
    }

    private static func checks(_ check: LandCheck, pr: PullRequest, kind: FixPrompt.Kind?) -> Row {
        let counts = pr.checks
        func row(_ tone: Tone, _ symbol: String, _ title: String, _ value: String = "", action: RowAction? = nil, hint: String? = nil) -> Row {
            Row(id: "checks", tone: check.blocks ? .blocking : tone, symbol: symbol, title: title, value: value, action: action, hint: hint)
        }
        switch check.state {
        case "passed": return row(.good, "checkmark.circle", "Checks pass", "\(counts.passed) of \(counts.total)")
        case "none": return row(.good, "checkmark.circle", "No checks")
        case "failed":
            let (action, hint) = fix(.failures, kind, hint: "Fix the failed checks")
            return row(.blocking, "xmark.circle", "Checks fail", "\(counts.failed) of \(counts.total)", action: action, hint: hint)
        case "running": return row(.note, "circle.dashed", "Checks running", "\(counts.passed + counts.failed) of \(counts.total) done")
        case "waiting": return row(.note, "hand.raised", "Checks wait for approval", "\(counts.waiting) waiting")
        default: return row(.note, "circle.dashed", "Checks \(check.state)")
        }
    }

    private static func review(_ check: LandCheck, pr: PullRequest, kind: FixPrompt.Kind?) -> Row {
        func row(_ tone: Tone, _ symbol: String, _ title: String, _ value: String = "", action: RowAction? = nil, hint: String? = nil) -> Row {
            Row(id: "review", tone: check.blocks ? .blocking : tone, symbol: symbol, title: title, value: value, action: action, hint: hint)
        }
        switch check.state {
        case "approved": return row(.good, "checkmark.circle", "Review approved", pr.approvals > 0 ? count(pr.approvals, "approval") : "")
        case "none": return row(.good, "checkmark.circle", "No review required")
        case "required": return row(.note, "eye", "Review needed")
        case "changes_requested":
            let (action, hint) = fix(.review, kind, hint: "Address the review")
            return row(.blocking, "xmark.circle", "Changes requested", pr.comments > 0 ? count(pr.comments, "comment") : "", action: action, hint: hint)
        default: return row(.note, "eye", "Review \(check.state)")
        }
    }

    private static func behind(_ check: LandCheck, pr: PullRequest) -> Row {
        let base = pr.base
        guard check.state == "behind" else {
            return Row(id: "behind_base", tone: check.blocks ? .blocking : .good, symbol: "checkmark.circle",
                       title: "Up to date with \(base)", value: "\(pr.behindBase) behind")
        }
        // Behind base blocks only when the base branch needs the PR up to date.
        return Row(id: "behind_base", tone: check.blocks ? .blocking : .note, symbol: check.blocks ? "xmark.circle" : "arrow.down.circle",
                   title: pr.behindBase > 0 ? "\(pr.behindBase) behind \(base)" : "Behind \(base)",
                   value: check.blocks ? "GitHub needs it up to date" : "Does not block the merge", action: .updateBranch)
    }

    private static func conflicts(_ check: LandCheck, pr: PullRequest, kind: FixPrompt.Kind?) -> Row {
        switch check.state {
        case "conflicting":
            let (action, hint) = fix(.conflicts, kind, hint: "Resolve the conflicts")
            return Row(id: "conflicts", tone: .blocking, symbol: "xmark.circle", title: "Conflicts with \(pr.base)", value: "",
                       action: action, hint: hint)
        case "checking":
            return Row(id: "conflicts", tone: check.blocks ? .blocking : .note, symbol: "circle.dashed", title: "Checking for conflicts", value: "")
        default:
            return Row(id: "conflicts", tone: check.blocks ? .blocking : .good, symbol: "checkmark.circle", title: "No conflicts", value: "")
        }
    }

    private static func github(_ check: LandCheck) -> Row {
        let tone: Tone = check.blocks ? .blocking : .note
        switch check.state {
        case "draft":
            return Row(id: "github", tone: tone, symbol: "xmark.circle", title: "Draft pull request", value: "Mark it ready on GitHub",
                       action: .openOnGitHub)
        case "blocked":
            return Row(id: "github", tone: tone, symbol: check.blocks ? "xmark.circle" : "exclamationmark.circle", title: "GitHub blocks the merge",
                       value: "", action: .openOnGitHub)
        default:
            return Row(id: "github", tone: tone, symbol: "circle.dashed", title: "GitHub is checking the merge", value: "")
        }
    }

    /// Uncommitted files and commits that are not pushed, as one row.
    private static func local(_ plan: LandResult, changes: LandCheck?, unpushed: LandCheck?) -> Row {
        let states = [changes?.state, unpushed?.state].compactMap { $0 }
        let blocks = (changes?.blocks ?? false) || (unpushed?.blocks ?? false)
        let value = "\(plan.changed) changed \u{00B7} \(plan.unpushed) not pushed"
        if states.contains("unknown") {
            return Row(id: "worktree", tone: .blocking, symbol: "xmark.circle", title: "Loam could not read the worktree", value: "",
                       action: nil, hint: "Check the worktree in a terminal")
        }
        guard blocks else {
            return Row(id: "worktree", tone: .good, symbol: "checkmark.circle", title: "Worktree saved and pushed", value: value)
        }
        let hint: String
        switch (plan.changed > 0, plan.unpushed > 0) {
        case (true, false): hint = "Commit or push \(plan.changed) \(plan.changed == 1 ? "file" : "files")"
        case (false, true): hint = "Push \(plan.unpushed) \(plan.unpushed == 1 ? "commit" : "commits")"
        default: hint = "Commit and push your work"
        }
        return Row(id: "worktree", tone: .blocking, symbol: "xmark.circle", title: "Worktree has local work", value: value, action: nil, hint: hint)
    }

    private static func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }

    // MARK: Where it stands

    /// The text of the Where it stands box: the sentence about the merge, then the current text.
    public struct WhereItStands: Equatable, Sendable {
        public var text: String
        /// The first sentence, which the box selects, so one key replaces it.
        public var sentence: String
    }

    /// "Merged #142 Link labels from plot brief." before the current text. The title comes from GitHub, so it
    /// becomes one line that shows each character it has (`FixPrompt.oneLine`). A title that ends in a mark keeps it.
    public static func whereItStands(merged number: Int, title: String, current: String) -> WhereItStands {
        let name = FixPrompt.oneLine(title).trimmingCharacters(in: .whitespaces)
        let head = "Merged \(StageMark.numberText(number))"
        let sentence = name.isEmpty ? head + "." : [".", "!", "?"].contains { name.hasSuffix($0) } ? "\(head) \(name)" : "\(head) \(name)."
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        return WhereItStands(text: rest.isEmpty ? sentence : sentence + " " + rest, sentence: sentence)
    }

    // MARK: The toast

    /// What the merge asked to keep, so the toast can tell a keep that you chose from one that the core made.
    public struct Request: Equatable, Sendable {
        public var keepWorktree: Bool
        public var keepRemoteBranch: Bool

        public init(keepWorktree: Bool = false, keepRemoteBranch: Bool = false) {
            self.keepWorktree = keepWorktree
            self.keepRemoteBranch = keepRemoteBranch
        }
    }

    /// The toast after a land that went through: "Merged #142. Removed the worktree link-labels." A keep that you
    /// chose needs no word. A step that the core could not do shows as a notice, and the Remove… pill of the
    /// Worktrees row says why when you press it.
    public static func toast(for result: LandResult, asked: Request) -> (text: String, kind: ActionBarModel.ToastKind) {
        let number = StageMark.numberText(result.pr.number)
        let name = result.worktree.name
        if result.merged {
            var text = "Merged \(number)."
            var kind = ActionBarModel.ToastKind.done
            if result.worktreeRemoved {
                text += " Removed the worktree \(name)."
            } else if !asked.keepWorktree {
                text += " Loam kept the worktree \(name)."
                kind = .notice
            }
            if !result.remoteBranchDeleted, !asked.keepRemoteBranch, result.remoteBranchNote != nil {
                text += " Loam kept the branch on GitHub."
                kind = .notice
            }
            return (text, kind)
        }
        if result.mergeLater, result.mergeQueue { return ("Added \(number) to the merge queue.", .done) }
        if result.mergeLater, result.auto { return ("\(number) will merge when its checks pass.", .done) }
        if result.mergeLater { return ("GitHub took \(number), but Loam does not see the merge yet.", .notice) }
        return ("Landed \(number).", .done)
    }
}
