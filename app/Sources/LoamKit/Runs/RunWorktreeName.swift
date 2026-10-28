import Foundation

/// The name of the worktree that a run gets when you approve it, as the core makes it (`freeName` and `slug` in
/// core/internal/run/run.go): the key of the issue and the title as one slug, such as eng-523-drag-a-link-to-reorder,
/// with a number added when the plot has a worktree of that name. The worktree name is also the branch name.
public enum RunWorktreeName {
    /// The longest slug. A slug cut short ends at a whole word.
    public static let slugMax = 48

    /// The name from the key and the title. `taken` are the names of the worktrees of the plot.
    public static func name(title: String, key: String, taken: Set<String>) -> String {
        var base = slug((key + " " + title).trimmingCharacters(in: .whitespaces))
        if base.isEmpty { base = "run" }
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base)-\(n)"
            n += 1
        }
        return name
    }

    /// The text as lowercase words of ASCII letters and digits, joined by "-".
    public static func slug(_ text: String) -> String {
        let fields = text.lowercased().unicodeScalars
            .split { !(("a"..."z").contains($0) || ("0"..."9").contains($0)) }
            .map { String(String.UnicodeScalarView($0)) }
        var words: [String] = []
        for word in fields {
            if (words + [word]).joined(separator: "-").count > slugMax && !words.isEmpty { break }
            words.append(word)
        }
        let out = words.joined(separator: "-")
        return out.count > slugMax ? String(out.prefix(slugMax)) : out
    }

    /// The key that the core names the worktree of a run by: the key of its issue. A recurring run has none.
    public static func key(of run: Run) -> String {
        guard let source = run.source, source.kind != "recurring" else { return "" }
        return source.key
    }
}
