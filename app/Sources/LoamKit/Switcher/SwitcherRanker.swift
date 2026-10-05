import Foundation

/// Ranks the switcher items (spec section 8.8).
public enum SwitcherRanker {
    /// Text after the title counts for less than a match in the title.
    static let otherTextWeight = (num: 3, den: 5)

    /// The query with the `>` prefix split off. `>` limits the list to actions.
    public static func parse(_ query: String) -> (actionsOnly: Bool, text: String) {
        guard query.hasPrefix(">") else { return (false, query) }
        return (true, String(query.dropFirst()))
    }

    /// `items` is in source order: plots, then panes, then links, then actions.
    /// `useTimes` maps an item ID to its last use.
    public static func rank(_ items: [SwitcherItem], query: String, useTimes: [String: Date]) -> [SwitcherResult] {
        let (actionsOnly, text) = parse(query)
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let pool = actionsOnly ? items.filter { $0.kind == .action } : items
        if words.isEmpty {
            return actionsOnly
                ? pool.map { SwitcherResult(item: $0, score: 0, titleMatches: []) }
                : emptyQueryOrder(pool, useTimes: useTimes)
        }
        var scored: [(offset: Int, result: SwitcherResult)] = []
        for (offset, item) in pool.enumerated() {
            guard let result = score(item, words: words) else { continue }
            scored.append((offset, result))
        }
        scored.sort { a, b in
            if a.result.score != b.result.score { return a.result.score > b.result.score }
            return moreRecent(a.result.item, b.result.item, offsetA: a.offset, offsetB: b.offset, useTimes)
        }
        return scored.map(\.result)
    }

    /// Panes that need you, then panes that are done and unread, then plots and panes by use.
    /// Links and actions show only after you type.
    static func emptyQueryOrder(_ items: [SwitcherItem], useTimes: [String: Date]) -> [SwitcherResult] {
        let shown = items.enumerated().filter { $0.element.kind == .plot || $0.element.kind == .pane }
        func tier(_ item: SwitcherItem) -> Int {
            guard item.kind == .pane else { return 2 }
            switch item.attention {
            case .needsYou: return 0
            case .doneUnread: return 1
            case .none: return 2
            }
        }
        let ordered = shown.sorted { a, b in
            let (ta, tb) = (tier(a.element), tier(b.element))
            if ta != tb { return ta < tb }
            return moreRecent(a.element, b.element, offsetA: a.offset, offsetB: b.offset, useTimes)
        }
        return ordered.map { SwitcherResult(item: $0.element, score: 0, titleMatches: []) }
    }

    /// Most recent use first. An item never used comes after every used item.
    /// Equal times keep source order.
    private static func moreRecent(_ a: SwitcherItem, _ b: SwitcherItem, offsetA: Int, offsetB: Int,
                                   _ useTimes: [String: Date]) -> Bool {
        switch (useTimes[a.id], useTimes[b.id]) {
        case let (ta?, tb?) where ta != tb: return ta > tb
        case (_?, nil): return true
        case (nil, _?): return false
        default: return offsetA < offsetB
        }
    }

    /// Every word must match the title or the other text. A query of several words may span
    /// the fields: "loam auth" finds the pane "auth fix" in the plot "Loam".
    static func score(_ item: SwitcherItem, words: [String]) -> SwitcherResult? {
        var total = 0
        var highlights = Set<Int>()
        for word in words {
            var best = 0
            var bestInTitle: [Int] = []
            if let match = FuzzyMatcher.match(word, in: item.title) {
                best = match.score
                bestInTitle = match.indices
            }
            for text in item.otherText {
                guard let match = FuzzyMatcher.match(word, in: text) else { continue }
                let weighted = max(1, match.score * otherTextWeight.num / otherTextWeight.den)
                if weighted > best { best = weighted; bestInTitle = [] }
            }
            guard best > 0 else { return nil }
            total += best
            highlights.formUnion(bestInTitle)
        }
        return SwitcherResult(item: item, score: total, titleMatches: highlights)
    }
}
