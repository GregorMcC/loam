import Foundation

/// A repo that the add repo row offers (ticket 78): a repo that a plot holds, or a git checkout in a
/// folder that holds one.
public struct RepoSuggestion: Equatable, Sendable, Identifiable {
    public var path: String
    /// True when a plot holds the repo. These come first.
    public var known: Bool

    public init(path: String, known: Bool) {
        self.path = path
        self.known = known
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    /// The path with the home folder as a tilde.
    public var shownPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

/// Finds and filters repo suggestions, and says what a drop on the panel adds.
public enum AddSources {
    /// The most suggestions the add row shows.
    public static let suggestionLimit = 5

    /// Every suggestion: the known repos, then each git checkout one level below a folder that holds a
    /// known repo, or below one of `roots`. A path shows once.
    public static func scan(known: [String], roots: [String], fileManager: FileManager = .default) -> [RepoSuggestion] {
        var seen = Set<String>()
        var out: [RepoSuggestion] = []
        for path in known.map(standard) where seen.insert(path).inserted {
            out.append(RepoSuggestion(path: path, known: true))
        }
        var folders: [String] = []
        for folder in known.map { (standard($0) as NSString).deletingLastPathComponent } + roots.map(standard)
        where !folders.contains(folder) {
            folders.append(folder)
        }
        for folder in folders {
            let names = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = (folder as NSString).appendingPathComponent(name)
                if isCheckout(path, fileManager: fileManager), seen.insert(path).inserted {
                    out.append(RepoSuggestion(path: path, known: false))
                }
            }
        }
        return out
    }

    /// The suggestions whose folder name or path holds `query`, with no case. An empty query matches
    /// all. Known repos come first, then a folder name that starts with the query. `excluding` holds the
    /// repos that the plot has already.
    public static func matching(_ query: String, in all: [RepoSuggestion], excluding: Set<String> = [],
                                limit: Int = suggestionLimit) -> [RepoSuggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let excluded = Set(excluding.map(standard))
        let hits = all.filter { s in
            !excluded.contains(s.path)
                && (q.isEmpty || [s.name, s.shownPath, s.path].contains { $0.lowercased().contains(q) })
        }
        let ranked = hits.enumerated().sorted { a, b in
            let ka = (a.element.known ? 0 : 1, a.element.name.lowercased().hasPrefix(q) ? 0 : 1, a.offset)
            let kb = (b.element.known ? 0 : 1, b.element.name.lowercased().hasPrefix(q) ? 0 : 1, b.offset)
            return ka < kb
        }
        return ranked.prefix(limit).map(\.element)
    }

    /// True when the text is a path, not a name to look up: it starts with `/` or `~`.
    public static func isPath(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("/") || t.hasPrefix("~")
    }

    /// What a drop on the panel adds.
    public enum Dropped: Equatable, Sendable {
        case repo(String)
        case link(String)
    }

    /// A folder with `.git` is a repo. Any other file or folder, and any web URL, is a link.
    public static func dropped(_ url: URL, fileManager: FileManager = .default) -> Dropped? {
        if url.isFileURL {
            let path = standard(url.path)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
            return isDir.boolValue && isCheckout(path, fileManager: fileManager) ? .repo(path) : .link(path)
        }
        guard url.scheme != nil, !url.absoluteString.isEmpty else { return nil }
        return .link(url.absoluteString)
    }

    /// A git checkout has `.git`: a folder, or a file in a linked worktree.
    static func isCheckout(_ path: String, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    static func standard(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}
