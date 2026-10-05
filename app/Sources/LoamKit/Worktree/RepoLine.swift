import Foundation

/// The window subtitle for a plot's main repo (ticket 68): the folder name and the branch,
/// as "loam · main". It reads `.git/HEAD` and runs no git process. A detached HEAD shows the
/// short commit. A folder that is not a repo shows the name only.
public struct RepoLine: Equatable, Sendable {
    public let name: String
    public let branch: String?

    public init(path: String, read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) {
        let url = URL(fileURLWithPath: path)
        name = url.lastPathComponent
        branch = Self.branch(repo: url, read: read)
    }

    public var text: String { branch.map { "\(name) \u{00B7} \($0)" } ?? name }

    static func branch(repo: URL, read: (String) -> String?) -> String? {
        let gitDir = gitDirectory(repo: repo, read: read)
        guard let head = read(gitDir.appendingPathComponent("HEAD").path)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
        return String(head.prefix(7))
    }

    /// The folder that holds `HEAD`: `.git`, or for a worktree or a submodule the folder that the
    /// `.git` file names. `HeadWatcher` watches this folder.
    public static func gitDirectory(
        path: String, read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> URL {
        gitDirectory(repo: URL(fileURLWithPath: path), read: read)
    }

    static func gitDirectory(repo: URL, read: (String) -> String?) -> URL {
        let dotGit = repo.appendingPathComponent(".git")
        // A worktree or a submodule: `.git` is a file that names the git folder.
        if let file = read(dotGit.path), let line = file.split(separator: "\n").first, line.hasPrefix("gitdir: ") {
            let target = String(line.dropFirst("gitdir: ".count))
            return target.hasPrefix("/") ? URL(fileURLWithPath: target) : repo.appendingPathComponent(target)
        }
        return dotGit
    }
}
