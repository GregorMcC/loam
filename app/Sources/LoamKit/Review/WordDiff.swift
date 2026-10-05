import Foundation

/// A per-word diff of two texts (spec 8.6). Removed words are red and struck out. Added words are green.
public enum WordDiff {
    public enum Kind: Equatable, Sendable { case same, removed, added }

    public struct Segment: Equatable, Sendable {
        public var kind: Kind
        public var text: String
        public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
    }

    /// Splits on white space and joins each run of words of one kind with one space.
    /// A very long text pair falls back to "all removed, then all added", to bound the work.
    public static func diff(old: String, new: String) -> [Segment] {
        let a = old.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = new.split(whereSeparator: \.isWhitespace).map(String.init)
        var raw: [(Kind, String)] = []
        if a.count * b.count > 4_000_000 {
            raw = a.map { (.removed, $0) } + b.map { (.added, $0) }
        } else {
            // Longest common subsequence, by dynamic programming over suffixes.
            var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
            var i = 0, j = 0
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, a[i] == b[j] {
                    raw.append((.same, a[i])); i += 1; j += 1
                } else if i < a.count, j == b.count || table[i + 1][j] >= table[i][j + 1] {
                    raw.append((.removed, a[i])); i += 1  // On a tie, removed words come first.
                } else {
                    raw.append((.added, b[j])); j += 1
                }
            }
        }
        var out: [Segment] = []
        for (kind, word) in raw {
            if let last = out.last, last.kind == kind {
                out[out.count - 1].text += " " + word
            } else {
                out.append(Segment(kind, word))
            }
        }
        return out
    }
}
