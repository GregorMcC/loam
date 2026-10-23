import Foundation

// Hand-written Codable types for the `loam --json` contract (docs/contract.md).
// Unknown keys are ignored, as the contract says.

public struct VersionInfo: Codable, Equatable, Sendable {
    public var version: String
    public var contractVersion: Int
    enum CodingKeys: String, CodingKey { case version, contractVersion = "contract_version" }
}

public struct PlotSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var what: String
    public var createdAt: String
    public var archived: Bool

    public init(id: String, name: String, what: String, createdAt: String, archived: Bool = false) {
        self.id = id
        self.name = name
        self.what = what
        self.createdAt = createdAt
        self.archived = archived
    }

    enum CodingKeys: String, CodingKey { case id, name, what, createdAt = "created_at", archived }
}

/// What a link target is.
public enum LinkKind: String, Codable, Equatable, Sendable {
    case notion, linear, github, url, path, vault
}

public struct Link: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var target: String
    public var note: String
    public var position: Int
    public var version: Int
}

/// A link inside a plot object. It adds `kind`, and `exists` for a path or vault link.
public struct PlotLink: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var target: String
    public var note: String
    public var position: Int
    public var version: Int
    public var kind: LinkKind
    /// Nil for a link that is not a path or vault link.
    public var exists: Bool?
}

public struct Repo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var path: String
    public var note: String
    public var main: Bool
    public var version: Int
    /// The setup command for worktrees. Nil when empty.
    public var setup: String?
    /// Files or globs to copy into each new worktree. Nil when empty.
    public var copy: [String]?
    /// What the app does when a refresh finds that GitHub merged the PR of a worktree of the repo (ticket 113).
    /// Nil from a core before ticket 113. The app reads nil as `.ask`.
    public var afterMerge: AfterMerge?
    enum CodingKeys: String, CodingKey {
        case id, path, note, main, version, setup, copy
        case afterMerge = "after_merge"
    }
}

/// The repo setting for a merge that Loam finds on GitHub (ticket 113): ask with a callout, remove the worktree, or
/// do nothing.
public enum AfterMerge: String, Codable, Equatable, Sendable, CaseIterable {
    case ask, remove, keep

    /// A value that this app does not know decodes as `.ask`, so a newer core cannot make the app remove a worktree.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AfterMerge(rawValue: raw) ?? .ask
    }
}

public struct Plot: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var what: String
    public var why: String
    public var whereItStands: String
    public var createdAt: String
    public var archived: Bool
    public var links: [PlotLink]
    public var repos: [Repo]
    /// Item to version, for `--expect`. Items: name, what, why, where, link:<id>, repo:<id>.
    public var versions: [String: Int]
    public var revision: Int
    enum CodingKeys: String, CodingKey {
        case id, name, what, why, archived, links, repos, versions, revision
        case whereItStands = "where_it_stands"
        case createdAt = "created_at"
    }
}

public struct Actor: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case cli, app, session }
    public var kind: Kind
    public var sessionID: String?
    public var loamStarted: Bool?
    enum CodingKeys: String, CodingKey {
        case kind, sessionID = "session_id", loamStarted = "loam_started"
    }
}

public struct ChangeEntry: Codable, Equatable, Sendable {
    public var item: String
    public var field: String
    /// Nil means the item is new.
    public var old: String?
    /// Nil means the change removed the item.
    public var new: String?
}

public struct Change: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var plotID: String
    public var at: String
    public var actor: Actor
    public var entries: [ChangeEntry]
    /// The ID of the change this change reverted.
    public var undoOf: Int?
    enum CodingKeys: String, CodingKey {
        case id, at, actor, entries
        case plotID = "plot_id", undoOf = "undo_of"
    }
}

public struct ChangesResponse: Codable, Equatable, Sendable {
    public var changes: [Change]
}

public struct ExportResponse: Codable, Equatable, Sendable {
    public var plots: [Plot]
    public var changes: [Change]?
}

public struct SessionRecord: Codable, Equatable, Sendable {
    public var sessionID: String
    public var plotID: String
    public var startFolder: String
    public var createdAt: String
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", plotID = "plot_id"
        case startFolder = "start_folder", createdAt = "created_at"
    }
}

/// One line that `loam hook` writes to the pane socket. `source` is set on
/// `SessionStart`, and `notificationType` on `Notification`.
public struct PaneEvent: Codable, Equatable, Sendable {
    public var event: String
    public var sessionID: String
    public var cwd: String
    public var at: String
    public var source: String?
    public var notificationType: String?
    enum CodingKeys: String, CodingKey {
        case event, sessionID = "session_id", cwd, at, source
        case notificationType = "notification_type"
    }
}

/// Result of a link or repo write. `changeID` is 0 when nothing changed.
public struct WriteResult: Codable, Equatable, Sendable {
    public var changeID: Int
    public var plot: String
    public var link: Link?
    public var repo: Repo?
    /// What a repo add could not do, such as switch a checkout with uncommitted changes (ticket 91).
    public var warnings: [String]?
    enum CodingKeys: String, CodingKey { case changeID = "change_id", plot, link, repo, warnings }
}

public struct MoveResult: Codable, Equatable, Sendable {
    public var plot: String
    public var position: Int
}

/// Result of `loam open`.
public struct OpenResult: Codable, Equatable, Sendable {
    public enum OpenedWith: String, Codable, Equatable, Sendable {
        case browser, obsidian, finder
        case defaultApp = "default_app"
    }
    public var plot: String
    public var linkID: String
    public var kind: LinkKind
    public var openedWith: OpenedWith
    enum CodingKeys: String, CodingKey { case plot, linkID = "link_id", kind, openedWith = "opened_with" }
}

public struct UndoResult: Codable, Equatable, Sendable {
    public var changeID: Int
    public var undone: Int
    public var plot: String
    enum CodingKeys: String, CodingKey { case changeID = "change_id", undone, plot }
}

public struct SetupStep: Codable, Equatable, Sendable {
    public var id: String
    public var done: Bool
    public var detail: String?
}

public struct SetupCheck: Codable, Equatable, Sendable {
    public var ok: Bool
    public var steps: [SetupStep]

    /// The steps the setup banner lists. Unknown step IDs show too: the app only reads `done`.
    public var pendingSteps: [SetupStep] { steps.filter { !$0.done } }
    public var needsBanner: Bool { !ok }
}

// MARK: Errors on the wire

public struct StaleItem: Codable, Equatable, Sendable {
    public var item: String
    public var expected: Int?
    public var current: Int?
    public var exists: Bool
    /// Current text of name, what, why, or where. Missing when empty.
    public var value: String?
    public var link: Link?
    public var repo: Repo?
    public var worktree: Worktree?
}

public struct StaleDetails: Codable, Equatable, Sendable {
    public var plotID: String
    public var items: [StaleItem]
    enum CodingKeys: String, CodingKey { case plotID = "plot_id", items }
}

public struct UndoClashDetails: Codable, Equatable, Sendable {
    public var changeID: Int
    public var plotID: String
    public var laterChanges: [Change]
    public var undoWouldWrite: [ChangeEntry]
    enum CodingKeys: String, CodingKey {
        case changeID = "change_id", plotID = "plot_id"
        case laterChanges = "later_changes", undoWouldWrite = "undo_would_write"
    }
}

/// The `details` of a `link_path_missing` error.
public struct LinkPathMissingDetails: Codable, Equatable, Sendable {
    public var plotID: String
    public var linkID: String
    public var path: String
    enum CodingKeys: String, CodingKey { case plotID = "plot_id", linkID = "link_id", path }
}

// MARK: Worktrees and delete

public struct Worktree: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var plotID: String
    /// The path of the repo.
    public var repo: String
    public var name: String
    public var branch: String
    /// The branch a new branch started from. Empty for a branch that existed.
    public var base: String
    public var path: String
    public var setupDone: Bool
    public var createdAt: String
    /// One line that says what the worktree is for. Empty when none is set.
    /// Nil from a core before ticket 114.
    public var goal: String?
    /// The link that the work started from. Nil when there is none.
    public var link: WorktreeLink?
    /// The change that last set the goal, or 0. Pass it as
    /// `--expect worktree:<id>=<version>`.
    public var version: Int?
    /// A land that waits for GitHub to merge the PR. Nil when no land waits.
    public var land: PendingLand?
    enum CodingKeys: String, CodingKey {
        case id, repo, name, branch, base, path, goal, link, version, land
        case plotID = "plot_id", setupDone = "setup_done", createdAt = "created_at"
    }
}

/// The link of a worktree. It belongs to the worktree, not to the links of the plot.
public struct WorktreeLink: Codable, Equatable, Sendable {
    public var target: String
    public var label: String
    /// The issue key for "Fixes" in a PR body: "ENG-482" for a Linear issue. For a GitHub
    /// issue, "#57" when the issue is in the repo of origin, else "owner/repo#57". Empty for
    /// any other link. Show it as it is: the seed shows the same key.
    public var key: String
    /// The plot link it was copied from. Empty for a URL given directly.
    public var linkID: String
    enum CodingKeys: String, CodingKey { case target, label, key, linkID = "link_id" }
}

/// The options of `loam worktree land` for a land that waits for GitHub (an auto merge, or a merge
/// queue), or after a merge, for the panes of the worktree to close. It belongs to the PR `pr`
/// only: a land of another PR does not apply it.
public struct PendingLand: Codable, Equatable, Sendable {
    /// The number of the PR.
    public var pr: Int
    /// The merge method. Empty with a merge queue.
    public var method: String
    public var auto: Bool
    public var mergeQueue: Bool
    public var keepWorktree: Bool
    public var keepRemoteBranch: Bool
    enum CodingKeys: String, CodingKey {
        case pr, method, auto
        case mergeQueue = "merge_queue", keepWorktree = "keep_worktree", keepRemoteBranch = "keep_remote_branch"
    }
}

public struct WorktreeStatus: Codable, Equatable, Sendable {
    public var worktree: Worktree
    /// True when the worktree folder is gone.
    public var missing: Bool
    public var changed: Int
    public var unpushed: Int
    public var merged: Bool
    public var mergedInto: String?
    /// Why a check failed. Nil when no check failed.
    public var error: String?
    /// The one stage of the worktree. The ship state fields are nil from a core
    /// that has no ship state.
    public var stage: WorktreeStage?
    /// The pull request of the branch from the last refresh. Nil when no PR has the branch as its head,
    /// and when the stage comes from the local checks after new work on a merged or closed PR.
    public var pr: PullRequest?
    /// Why the ship state is missing or old: the result of the last refresh.
    public var prNote: PRNote?
    /// When the ship state came from GitHub. Nil when GitHub never answered.
    public var prCheckedAt: String?
    /// The GitHub page that compares the branch with its base. Only for `.pushedNoPR`.
    public var compareURL: String?
    enum CodingKeys: String, CodingKey {
        case worktree, missing, changed, unpushed, merged, error, stage, pr
        case mergedInto = "merged_into", prNote = "pr_note", prCheckedAt = "pr_checked_at", compareURL = "compare_url"
    }
}

/// The stage of a worktree, in the order that the core checks them
/// (docs/contract.md, "Ship state of worktrees").
public enum WorktreeStage: String, Codable, Equatable, Sendable, CaseIterable {
    case merged, closed
    case inMergeQueue = "in_merge_queue"
    case conflicts
    case changesRequested = "changes_requested"
    case checksFailed = "checks_failed"
    case approvalNeeded = "approval_needed"
    case draft
    case behindBase = "behind_base"
    case checksRunning = "checks_running"
    case waitingForReview = "waiting_for_review"
    /// GitHub blocks the merge for a reason that no other stage covers.
    case blocked
    case readyToMerge = "ready_to_merge"
    case pushedNoPR = "pushed_no_pr"
    case notPushed = "not_pushed"
    /// Nothing to show.
    case noStage = ""

    /// A stage that this app does not know decodes as `.noStage`, so a newer
    /// core cannot break the list. The app shows nothing for it.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WorktreeStage(rawValue: raw) ?? .noStage
    }
}

/// Why the ship state of a worktree is missing or old.
public enum PRNote: String, Codable, Equatable, Sendable, CaseIterable {
    case ghMissing = "gh_missing"
    case ghSignedOut = "gh_signed_out"
    /// gh cannot read the repo: no access, or SSO not authorized.
    case noAccess = "no_access"
    case noGitHubRemote = "no_github_remote"
    case offline
    case rateLimited = "rate_limited"
    /// The last refresh got an answer from GitHub, or no refresh ran.
    case noNote = ""

    /// A note that this app does not know decodes as `.noNote`, as for `WorktreeStage`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PRNote(rawValue: raw) ?? .noNote
    }
}

/// A pull request on GitHub. The fields from `behindBase` to `passedChecks`
/// are for an open PR. They are 0 or empty for a merged or closed PR.
public struct PullRequest: Codable, Equatable, Sendable {
    public var number: Int
    public var title: String
    public var url: String
    /// OPEN, CLOSED, or MERGED.
    public var state: String
    public var draft: Bool
    /// MERGEABLE, CONFLICTING, or UNKNOWN while GitHub checks.
    public var mergeable: String
    /// The mergeStateStatus of GitHub, such as CLEAN, BEHIND, BLOCKED, or DIRTY.
    public var mergeState: String
    /// APPROVED, CHANGES_REQUESTED, or REVIEW_REQUIRED. Empty when the base branch needs no review.
    public var reviewDecision: String
    public var inMergeQueue: Bool
    /// The place in the merge queue, from 1. Zero out of the queue.
    public var queuePosition: Int
    /// The base branch name, such as main.
    public var base: String
    /// The head branch name.
    public var head: String
    public var headOID: String
    /// Nil when the PR is not merged.
    public var mergedAt: String?
    /// Nil when the PR is open.
    public var closedAt: String?
    public var commits: Int
    /// The commits of the base branch that the head does not have.
    public var behindBase: Int
    /// The reviewers with write access whose last review approves.
    public var approvals: Int
    /// The review threads that are not resolved.
    public var comments: Int
    public var checks: PRCheckCounts
    public var failedChecks: [PRCheck]
    /// The checks that passed, in the order of GitHub. A skipped or neutral check passed too, so the list is as
    /// long as `checks.passed`. Nil from a core older than ticket 116. A cache row from before it gives an empty list.
    public var passedChecks: [PRCheck]?
    enum CodingKeys: String, CodingKey {
        case number, title, url, state, draft, mergeable, base, head, commits, approvals, comments, checks
        case mergeState = "merge_state", reviewDecision = "review_decision", inMergeQueue = "in_merge_queue"
        case queuePosition = "queue_position", headOID = "head_oid", mergedAt = "merged_at", closedAt = "closed_at"
        case behindBase = "behind_base", failedChecks = "failed_checks", passedChecks = "passed_checks"
    }
}

/// The checks of the head commit of a PR. `total` counts every check. The other
/// counts are of the first 100 checks. A cancelled or stale check counts only in `total`.
public struct PRCheckCounts: Codable, Equatable, Sendable {
    /// The summary of GitHub: SUCCESS, FAILURE, ERROR, PENDING, or EXPECTED. Empty when the head has no checks.
    public var state: String
    public var total: Int
    public var passed: Int
    public var failed: Int
    public var running: Int
    /// The checks that wait for a person, such as a workflow that needs approval.
    public var waiting: Int
    /// The checks that the base branch needs to pass before a merge. Nil from an older core.
    public var required: Int?
    /// The required checks that passed. Nil from an older core.
    public var requiredPassed: Int?
    enum CodingKeys: String, CodingKey {
        case state, total, passed, failed, running, waiting, required
        case requiredPassed = "required_passed"
    }
}

/// A check of a PR, one that failed or one that passed.
public struct PRCheck: Codable, Equatable, Sendable {
    /// A GitHub Actions job has its workflow name first, such as "lint / swiftformat".
    public var name: String
    /// The page of the check, with its log.
    public var url: String
    /// The run time in seconds. Zero when GitHub gives no start or end.
    public var duration: Int
    /// True when the base branch needs the check to pass before a merge.
    public var required: Bool
    /// The GitHub Actions run of the check, which `loam worktree rerun` runs again.
    /// Nil for a check that is not a job of GitHub Actions.
    public var runID: Int?
    enum CodingKeys: String, CodingKey {
        case name, url, duration, required
        case runID = "run_id"
    }
}

public struct WorktreeNewResult: Codable, Equatable, Sendable {
    public var worktree: Worktree
    /// Files copied into the worktree, relative to the repo.
    public var copied: [String]
}

/// `loam worktree new --dry-run --json`. It changes nothing.
public struct WorktreeCheck: Codable, Equatable, Sendable {
    public var name: String
    /// The folder name that the worktree would get, such as web-fix-login.
    public var folder: String
    public var validName: Bool
    /// Why the name is not a good branch name. Nil when it is valid.
    public var nameError: String?
    public var worktreeExists: Bool
    public var branchExists: Bool
    /// The base of a new branch when none is given. Empty when it is not known.
    public var defaultBase: String
    /// The default base first, then the branches of origin, then the local branches.
    public var bases: [String]
    enum CodingKeys: String, CodingKey {
        case name, folder, bases
        case validName = "valid_name", nameError = "name_error", worktreeExists = "worktree_exists"
        case branchExists = "branch_exists", defaultBase = "default_base"
    }
}

/// `loam worktree edit --json`.
public struct WorktreeEditResult: Codable, Equatable, Sendable {
    /// 0 when the edit changed nothing.
    public var changeID: Int
    public var plot: String
    public var worktree: Worktree
    enum CodingKeys: String, CodingKey { case changeID = "change_id", plot, worktree }
}

public struct WorktreeRmResult: Codable, Equatable, Sendable {
    public var worktree: Worktree
    public var branchDeleted: Bool
    /// Why the local branch is still there. Nil when it was deleted.
    public var branchNote: String?
    enum CodingKeys: String, CodingKey {
        case worktree, branchDeleted = "branch_deleted", branchNote = "branch_note"
    }
}

/// A merge method of GitHub, for `LoamClient.worktreeLand`.
public enum MergeMethod: String, Codable, Equatable, Sendable, CaseIterable {
    case merge, squash, rebase
}

/// One check of a land (docs/contract.md, "Land, rerun, and update").
public struct LandCheck: Codable, Equatable, Sendable {
    /// checks, review, behind_base, conflicts, github, local_changes, or unpushed_commits for an open PR.
    /// work_after_pr for a merged PR.
    public var name: String
    /// The state of the check, such as passed, failed, changes_requested, behind, conflicting, or draft.
    public var state: String
    /// True when the check stops the land.
    public var blocks: Bool
}

/// What `loam worktree land` did, or with `dryRun`, the plan.
public struct LandResult: Codable, Equatable, Sendable {
    /// The worktree, with the land that it records after the land.
    public var worktree: Worktree
    /// Says that the worktree recorded a land of another PR. That land is stale: its keeps
    /// do not apply, and a land that is not a dry run clears it.
    public var landNote: String?
    /// The PR before the merge.
    public var pr: PullRequest
    public var stage: WorktreeStage
    public var changed: Int
    public var unpushed: Int
    /// The merge methods that the repo allows. Empty for a PR that is merged.
    public var methods: [String]
    /// The method that GitHub offers first. Empty for a PR that is merged.
    public var defaultMethod: String
    /// The method of the land. Empty with a merge queue, and for a PR that is merged.
    public var method: String
    /// True when the base branch has a merge queue. The land adds the PR to the queue.
    public var mergeQueue: Bool
    public var auto: Bool
    /// Every check, in the order of the core. For a PR that is merged, work_after_pr only.
    public var checks: [LandCheck]
    /// True when no check blocks.
    public var ready: Bool
    public var dryRun: Bool
    /// True when GitHub says that the PR is merged.
    public var merged: Bool
    /// True when GitHub merges later: an auto merge, or a merge queue. Also true when the core
    /// cannot see the merge yet (`mergeNote`).
    public var mergeLater: Bool
    /// Why the core does not see the merge yet.
    public var mergeNote: String?
    public var remoteBranchDeleted: Bool
    public var remoteBranchNote: String?
    public var worktreeRemoved: Bool
    public var worktreeNote: String?
    public var branchDeleted: Bool
    public var branchNote: String?
    enum CodingKeys: String, CodingKey {
        case worktree, pr, stage, changed, unpushed, methods, method, auto, checks, ready, merged
        case landNote = "land_note"
        case defaultMethod = "default_method", mergeQueue = "merge_queue", dryRun = "dry_run", mergeLater = "merge_later"
        case mergeNote = "merge_note", remoteBranchDeleted = "remote_branch_deleted", remoteBranchNote = "remote_branch_note"
        case worktreeRemoved = "worktree_removed", worktreeNote = "worktree_note"
        case branchDeleted = "branch_deleted", branchNote = "branch_note"
    }
}

/// A GitHub Actions run with a failed check, which `loam worktree rerun` runs again.
public struct FailedRun: Codable, Equatable, Sendable {
    public var id: Int
    /// True when GitHub runs the failed jobs of the run again.
    public var started: Bool
    /// Why GitHub did not start the run. Nil when it started.
    public var note: String?
}

/// What `loam worktree rerun` started again.
public struct RerunResult: Codable, Equatable, Sendable {
    public var worktree: Worktree
    public var pr: PullRequest
    /// Each GitHub Actions run with a failed check: whether it started again, or why not.
    public var runs: [FailedRun]
    /// The failed checks that are not jobs of GitHub Actions. The core cannot run them again.
    public var skippedChecks: [String]
    enum CodingKeys: String, CodingKey { case worktree, pr, runs, skippedChecks = "skipped_checks" }
}

/// What `loam worktree update` did.
public struct UpdateResult: Codable, Equatable, Sendable {
    public var worktree: Worktree
    public var pr: PullRequest
    /// True when the local repo has the new PR head.
    public var fetched: Bool
    /// Why the fetch failed. GitHub still has the update.
    public var fetchNote: String?
    enum CodingKeys: String, CodingKey { case worktree, pr, fetched, fetchNote = "fetch_note" }
}

/// The details of a land that a check blocks (exit 16).
public struct NotReadyDetails: Codable, Equatable, Sendable {
    /// The checks that block.
    public var checks: [LandCheck]
}

/// The details of a refused `loam worktree rm` (ticket 113). The message names flags of the CLI, so the app words the
/// refusal from these.
public struct RemovalRefusal: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case unsafeWork = "unsafe_work"
        case openPanes = "open_panes"
    }
    public var refusal: Reason
    /// The files with uncommitted changes.
    public var changed: Int?
    /// The commits that are not pushed and that the merged PR does not hold.
    public var unpushed: Int?
    /// The error of a check that failed.
    public var checkError: String?
    /// The panes that are open in the worktree.
    public var openPanes: Int?
    enum CodingKeys: String, CodingKey {
        case refusal, changed, unpushed, checkError = "check_error", openPanes = "open_panes"
    }
}

public struct DeleteResult: Codable, Equatable, Sendable {
    public var plot: String
    public var name: String
    /// The new path of the plot folder. Empty when the plot had no folder.
    public var trash: String
    /// Folders of Claude Code's own files that Loam did not remove.
    public var claudeFiles: [String]
    enum CodingKeys: String, CodingKey { case plot, name, trash, claudeFiles = "claude_files" }
}

/// The JSON error body. `details` depends on `kind`, so it stays raw here.
struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        var kind: String
        var exitCode: Int
        var message: String
        var details: RawJSON?
        enum CodingKeys: String, CodingKey { case kind, exitCode = "exit_code", message, details }
    }
    var error: Body
}

/// Keeps a JSON value as bytes, so a later step can decode it as a chosen type.
struct RawJSON: Decodable {
    var data: Data
    init(from decoder: Decoder) throws {
        data = try JSONEncoder().encode(JSONValue(from: decoder))
    }
}

enum JSONValue: Codable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
