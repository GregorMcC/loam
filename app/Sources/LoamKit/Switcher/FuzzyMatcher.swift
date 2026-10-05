import Foundation

/// Fuzzy match of one word against one text. Every character of the word must appear in
/// the text in order. The score is higher for matches at the start, at word starts, and
/// in runs. The case does not matter.
public enum FuzzyMatcher {
    public struct Match: Equatable, Sendable {
        public var score: Int
        /// Character offsets in the text that the word matched.
        public var indices: [Int]
    }

    static let maxTextLength = 256
    private static let base = 16
    private static let consecutive = 24
    private static let wordStart = 20
    private static let textStart = 30
    private static let camelHump = 15
    private static let gapCost = 2
    private static let exactBonus = 40
    private static let separators: Set<Character> = [" ", "-", "_", "/", ".", ":", "(", ")", "\\", "@", "#", "?", "&", "="]

    public static func match(_ word: String, in text: String) -> Match? {
        let query = word.map(fold)
        guard !query.isEmpty else { return nil }
        let original = Array(text.prefix(maxTextLength))
        let chars = original.map(fold)
        let n = chars.count, m = query.count
        guard m <= n else { return nil }

        func bonus(_ j: Int) -> Int {
            if j == 0 { return textStart }
            if separators.contains(original[j - 1]) { return wordStart }
            if original[j - 1].isLowercase, original[j].isUppercase { return camelHump }
            return 0
        }

        let none = Int.min / 2
        var previous = [Int](repeating: none, count: n)
        var from = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)
        for j in 0..<n where chars[j] == query[0] {
            previous[j] = base + bonus(j) - min(j, 8)
        }
        if m > 1 {
            for i in 1..<m {
                var current = [Int](repeating: none, count: n)
                // The best earlier cell with the gap cost folded in: previous[k] + gapCost * k.
                var run = none, runAt = -1
                for j in 0..<n {
                    if j >= 2, previous[j - 2] > none, previous[j - 2] + gapCost * (j - 2) > run {
                        run = previous[j - 2] + gapCost * (j - 2)
                        runAt = j - 2
                    }
                    guard chars[j] == query[i] else { continue }
                    var best = none, at = -1
                    if j >= 1, previous[j - 1] > none { best = previous[j - 1] + consecutive; at = j - 1 }
                    if runAt >= 0 {
                        let viaGap = run - gapCost * (j - 1)
                        if viaGap > best { best = viaGap; at = runAt }
                    }
                    guard at >= 0 else { continue }
                    current[j] = best + base + bonus(j)
                    from[i][j] = at
                }
                previous = current
            }
        }
        var end = -1, top = none
        for j in 0..<n where previous[j] > top { top = previous[j]; end = j }
        guard end >= 0 else { return nil }
        var indices = [Int](repeating: 0, count: m)
        var j = end
        for i in stride(from: m - 1, through: 0, by: -1) {
            indices[i] = j
            if i > 0 { j = from[i][j] }
        }
        var score = top
        if m == n { score += exactBonus }
        return Match(score: max(1, score), indices: indices)
    }

    private static func fold(_ c: Character) -> Character {
        c.lowercased().first ?? c
    }
}
