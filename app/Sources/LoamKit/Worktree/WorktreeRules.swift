import Foundation

/// The worktree a pane runs in. A pane spec holds it, so the pane header can show the branch.
public struct WorktreeRef: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var branch: String
    /// The worktree folder.
    public var path: String
    /// The normal checkout of the repo, so the sidebar can nest the worktree under it (ticket 92).
    /// Nil in a pane that was saved before the field existed.
    public var repo: String?

    public init(id: String, name: String, branch: String, path: String, repo: String? = nil) {
        self.id = id
        self.name = name
        self.branch = branch
        self.path = path
        self.repo = repo
    }

    public init(_ worktree: Worktree) {
        self.init(id: worktree.id, name: worktree.name, branch: worktree.branch, path: worktree.path, repo: worktree.repo)
    }
}

/// What the app does when you ask to remove a worktree (spec section 9). The core checks the same
/// rules again in `loam worktree rm`, so a stale view cannot remove a worktree that is not safe.
public enum WorktreeRemovalPlan: Equatable, Sendable {
    /// Panes are open in the worktree, or saved panes have not resumed. Nothing is removed.
    case refusedOpenPanes(open: Int, saved: Int)
    /// The worktree holds work that removal loses, or a check failed. `force` must be on.
    case needsForce(changed: Int, unpushed: Int, checkError: String?)
    /// Nothing is lost. `mergeNote` says where the branch stands.
    case ready(mergeNote: String)

    /// The words for a person. Simplified Technical English.
    public func message(for worktree: Worktree) -> String {
        let name = worktree.name
        switch self {
        case .refusedOpenPanes(let open, let saved):
            var parts: [String] = []
            if open > 0 { parts.append("\(open) \(open == 1 ? "pane is" : "panes are") open in the worktree \(name).") }
            if saved > 0 { parts.append("\(saved) saved \(saved == 1 ? "pane has" : "panes have") not resumed.") }
            parts.append("Close \(open + saved == 1 ? "it" : "them") first.")
            return parts.joined(separator: " ")
        case .needsForce(let changed, let unpushed, let checkError):
            var lost: [String] = []
            if changed > 0 { lost.append("\(changed) \(changed == 1 ? "file has" : "files have") uncommitted changes") }
            if unpushed > 0 { lost.append("\(unpushed) \(unpushed == 1 ? "commit is" : "commits are") not pushed") }
            var text = lost.isEmpty ? "" : "In the worktree \(name), " + lost.joined(separator: " and ") + ". Removing it loses that work."
            if let checkError {
                text += (text.isEmpty ? "" : " ") + "A check failed: \(checkError). Loam cannot tell if the work is safe."
            }
            return text
        case .ready(let mergeNote):
            return "Remove the worktree \(name)? \(mergeNote)"
        }
    }

    /// False for a refusal: there is nothing to confirm.
    public var needsConfirmation: Bool {
        if case .refusedOpenPanes = self { return false }
        return true
    }
}

public enum WorktreeRules {
    /// True when `folder` is the worktree folder or lies inside it. Symbolic links are resolved.
    public static func contains(worktreePath: String, folder: String) -> Bool {
        let root = resolved(worktreePath)
        let other = resolved(folder)
        return other == root || other.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// How many of the folders lie in the worktree.
    public static func count(in worktree: Worktree, folders: [String]) -> Int {
        folders.filter { contains(worktreePath: worktree.path, folder: $0) }.count
    }

    /// The removal plan. Open and saved panes come first, because `--force` never skips them.
    public static func plan(for status: WorktreeStatus, openPanes: Int, savedPanes: Int) -> WorktreeRemovalPlan {
        if openPanes > 0 || savedPanes > 0 { return .refusedOpenPanes(open: openPanes, saved: savedPanes) }
        if status.changed > 0 || status.unpushed > 0 || status.error != nil {
            return .needsForce(changed: status.changed, unpushed: status.unpushed, checkError: status.error)
        }
        let note: String
        if let into = status.mergedInto {
            note = status.merged
                ? "The branch is merged into \(into)."
                : "The branch is not merged into \(into). Loam keeps the local branch."
        } else {
            note = "Loam cannot tell if the branch is merged."
        }
        return .ready(mergeNote: note)
    }

    /// The line that "Session ended" adds for a pane whose worktree is gone. Nil when the folder exists.
    /// `status` is nil when the core no longer lists the worktree.
    public static func endedNote(for ref: WorktreeRef, status: WorktreeStatus?) -> String? {
        if status == nil || status?.missing == true {
            return "The worktree \(ref.name) is gone. Its folder is missing: \(ref.path)"
        }
        return nil
    }
}
