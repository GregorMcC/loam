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
    enum CodingKeys: String, CodingKey {
        case id, repo, name, branch, base, path
        case plotID = "plot_id", setupDone = "setup_done", createdAt = "created_at"
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
    enum CodingKeys: String, CodingKey {
        case worktree, missing, changed, unpushed, merged, error
        case mergedInto = "merged_into"
    }
}

public struct WorktreeNewResult: Codable, Equatable, Sendable {
    public var worktree: Worktree
    /// Files copied into the worktree, relative to the repo.
    public var copied: [String]
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
