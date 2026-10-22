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
    enum CodingKeys: String, CodingKey {
        case id, repo, name, branch, base, path, goal, link, version
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

/// A pull request on GitHub. The fields from `behindBase` to `failedChecks`
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
    public var failedChecks: [FailedCheck]
    enum CodingKeys: String, CodingKey {
        case number, title, url, state, draft, mergeable, base, head, commits, approvals, comments, checks
        case mergeState = "merge_state", reviewDecision = "review_decision", inMergeQueue = "in_merge_queue"
        case queuePosition = "queue_position", headOID = "head_oid", mergedAt = "merged_at", closedAt = "closed_at"
        case behindBase = "behind_base", failedChecks = "failed_checks"
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

/// A check of a PR that failed.
public struct FailedCheck: Codable, Equatable, Sendable {
    /// A GitHub Actions job has its workflow name first, such as "lint / swiftformat".
    public var name: String
    /// The page of the check, with its log.
    public var url: String
    /// The run time in seconds. Zero when GitHub gives no start or end.
    public var duration: Int
    /// True when the base branch needs the check to pass before a merge.
    public var required: Bool
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
