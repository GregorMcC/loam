import CoreGraphics
import Foundation

public typealias PaneID = UUID

/// How a split lays out its two children.
public enum SplitAxis: String, Codable, Sendable {
    /// First child on the left, second on the right (Ghostty "split right").
    case sideBySide
    /// First child on top, second below (Ghostty "split down").
    case stacked
}

/// The layout of one tab: a binary tree of panes. Value type, so a change makes a new tree.
public indirect enum SplitTree: Equatable, Sendable {
    case leaf(PaneID)
    case split(axis: SplitAxis, ratio: Double, first: SplitTree, second: SplitTree)

    /// Panes in layout order: left to right, top to bottom.
    public var paneIDs: [PaneID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, _, let first, let second): first.paneIDs + second.paneIDs
        }
    }

    public func contains(_ pane: PaneID) -> Bool { paneIDs.contains(pane) }

    /// Splits `pane` in two at ratio 0.5. The new pane is the second child.
    /// An unknown `pane` changes nothing.
    public func splitting(_ pane: PaneID, axis: SplitAxis, inserting new: PaneID) -> SplitTree {
        switch self {
        case .leaf(let id):
            id == pane ? .split(axis: axis, ratio: 0.5, first: .leaf(id), second: .leaf(new)) : self
        case .split(let a, let r, let first, let second):
            .split(axis: a, ratio: r, first: first.splitting(pane, axis: axis, inserting: new),
                   second: second.splitting(pane, axis: axis, inserting: new))
        }
    }

    /// Removes `pane`. Its sibling takes the space. Returns nil when no pane is left.
    public func removing(_ pane: PaneID) -> SplitTree? {
        switch self {
        case .leaf(let id):
            return id == pane ? nil : self
        case .split(let a, let r, let first, let second):
            switch (first.removing(pane), second.removing(pane)) {
            case (nil, let rest?), (let rest?, nil): return rest
            case (let f?, let s?): return .split(axis: a, ratio: r, first: f, second: s)
            case (nil, nil): return nil
            }
        }
    }

    /// The frame of each pane inside `rect`. `gap` is the divider width between siblings.
    public func frames(in rect: CGRect, gap: CGFloat = 0) -> [PaneID: CGRect] {
        switch self {
        case .leaf(let id):
            return [id: rect]
        case .split(let axis, let ratio, let first, let second):
            let rects = Self.childRects(axis: axis, ratio: ratio, in: rect, gap: gap)
            return first.frames(in: rects.first, gap: gap).merging(second.frames(in: rects.second, gap: gap)) { $1 }
        }
    }

    /// Where one split puts its two children and the divider between them inside `rect`. The first
    /// child's length rounds down, so every pane lands on whole points. The y axis grows upward
    /// (AppKit), so a stacked split puts the first pane on top.
    private static func childRects(axis: SplitAxis, ratio: Double, in rect: CGRect, gap: CGFloat)
        -> (first: CGRect, divider: CGRect, second: CGRect) {
        switch axis {
        case .sideBySide:
            let w = ((rect.width - gap) * ratio).rounded(.down)
            return (first: CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height),
                    divider: CGRect(x: rect.minX + w, y: rect.minY, width: gap, height: rect.height),
                    second: CGRect(x: rect.minX + w + gap, y: rect.minY, width: rect.width - w - gap, height: rect.height))
        case .stacked:
            let h = ((rect.height - gap) * ratio).rounded(.down)
            let secondH = rect.height - h - gap
            return (first: CGRect(x: rect.minX, y: rect.minY + secondH + gap, width: rect.width, height: h),
                    divider: CGRect(x: rect.minX, y: rect.minY + secondH, width: rect.width, height: gap),
                    second: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: secondH))
        }
    }

    /// The next pane in layout order. Wraps. Nil when `pane` is not in the tree.
    public func pane(after pane: PaneID) -> PaneID? { step(from: pane, by: 1) }
    public func pane(before pane: PaneID) -> PaneID? { step(from: pane, by: -1) }

    /// The pane next to `pane` on one side (Ghostty `goto_split:left` and the others): of the panes
    /// that lie on that side and overlap it along the other axis, the nearest. Nil at the edge.
    public func pane(nextTo pane: PaneID, toward direction: ResizeDirection) -> PaneID? {
        let frames = frames(in: CGRect(x: 0, y: 0, width: 10_000, height: 10_000))
        guard let from = frames[pane] else { return nil }
        let candidates = frames.compactMap { id, rect -> (PaneID, CGFloat)? in
            guard id != pane else { return nil }
            let alongX = max(rect.minX, from.minX) < min(rect.maxX, from.maxX)
            let alongY = max(rect.minY, from.minY) < min(rect.maxY, from.maxY)
            switch direction {
            case .left: return rect.maxX <= from.minX && alongY ? (id, from.minX - rect.maxX) : nil
            case .right: return rect.minX >= from.maxX && alongY ? (id, rect.minX - from.maxX) : nil
            case .up: return rect.minY >= from.maxY && alongX ? (id, rect.minY - from.maxY) : nil
            case .down: return rect.maxY <= from.minY && alongX ? (id, from.minY - rect.maxY) : nil
            }
        }
        // Nearest first. A tie goes to layout order, so the result does not depend on hashing.
        let order = paneIDs
        return candidates.min { a, b in
            a.1 != b.1 ? a.1 < b.1 : order.firstIndex(of: a.0)! < order.firstIndex(of: b.0)!
        }?.0
    }

    private func step(from pane: PaneID, by offset: Int) -> PaneID? {
        let ids = paneIDs
        guard let i = ids.firstIndex(of: pane) else { return nil }
        return ids[(i + offset + ids.count) % ids.count]
    }

    // MARK: Ratios

    /// The ratio a divider may take. The model keeps a split away from 0 and 1.
    public static let ratioRange: ClosedRange<Double> = 0.05...0.95

    static func clamp(_ ratio: Double) -> Double {
        min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }

    /// Sets the ratio of the split at `path` (0 for first child, 1 for second, from the root).
    /// The ratio is clamped. A path that reaches no split changes nothing.
    public func settingRatio(_ ratio: Double, at path: [Int]) -> SplitTree {
        guard case .split(let axis, let r, let first, let second) = self else { return self }
        guard let head = path.first else {
            return .split(axis: axis, ratio: Self.clamp(ratio), first: first, second: second)
        }
        let rest = Array(path.dropFirst())
        switch head {
        case 0: return .split(axis: axis, ratio: r, first: first.settingRatio(ratio, at: rest), second: second)
        case 1: return .split(axis: axis, ratio: r, first: first, second: second.settingRatio(ratio, at: rest))
        default: return self
        }
    }

    /// Gives panes equal size. Nested splits of the same axis count each pane, as Ghostty does.
    public func equalized() -> SplitTree {
        guard case .split(let axis, _, let first, let second) = self else { return self }
        let f = first.weight(along: axis), s = second.weight(along: axis)
        return .split(axis: axis, ratio: Double(f) / Double(f + s), first: first.equalized(), second: second.equalized())
    }

    private func weight(along axis: SplitAxis) -> Int {
        if case .split(let a, _, let first, let second) = self, a == axis {
            return first.weight(along: axis) + second.weight(along: axis)
        }
        return 1
    }

    public enum ResizeDirection: Sendable { case left, right, up, down }

    /// Moves the nearest divider on the `direction` side of `pane` by `delta` (a fraction of the split).
    /// Nothing changes when the pane has no divider on that side.
    public func resizing(_ pane: PaneID, toward direction: ResizeDirection, by delta: Double) -> SplitTree {
        move(pane, direction, delta) ?? self
    }

    /// Nil when no divider exists on that side. A divider at its limit still counts, so it never hands over to a farther one.
    private func move(_ pane: PaneID, _ direction: ResizeDirection, _ delta: Double) -> SplitTree? {
        let axis: SplitAxis = (direction == .left || direction == .right) ? .sideBySide : .stacked
        let growsFirst = direction == .right || direction == .down
        guard case .split(let a, let r, let first, let second) = self else { return nil }
        let inFirst = first.contains(pane)
        guard inFirst || second.contains(pane) else { return nil }
        if let inner = (inFirst ? first : second).move(pane, direction, delta) {
            return inFirst ? .split(axis: a, ratio: r, first: inner, second: second)
                           : .split(axis: a, ratio: r, first: first, second: inner)
        }
        // The divider of this split is on the wanted side when the pane sits before it and we move toward it.
        guard a == axis, inFirst == growsFirst else { return nil }
        return .split(axis: a, ratio: Self.clamp(r + (growsFirst ? delta : -delta)), first: first, second: second)
    }

    /// One draggable divider: where it is, and which split it belongs to.
    public struct Divider: Equatable, Sendable {
        public var path: [Int]
        public var axis: SplitAxis
        public var frame: CGRect
        /// The rect the whole split occupies.
        public var parent: CGRect
        public var gap: CGFloat

        /// The ratio that puts the divider centre under `point`, keeping each pane at least `minPaneSize` long.
        public func ratio(at point: CGPoint, minPaneSize: CGFloat) -> Double {
            let available: CGFloat, offset: CGFloat
            switch axis {
            case .sideBySide:
                available = parent.width - gap
                offset = point.x - parent.minX - gap / 2
            case .stacked:
                available = parent.height - gap
                offset = parent.maxY - point.y - gap / 2
            }
            guard available > 0 else { return 0.5 }
            let minRatio = Double(minPaneSize / available)
            if minRatio >= 0.5 { return 0.5 }
            return min(max(Double(offset / available), minRatio), 1 - minRatio)
        }
    }

    /// The dividers of every split inside `rect`, parents before children.
    public func dividers(in rect: CGRect, gap: CGFloat = 0, path: [Int] = []) -> [Divider] {
        guard case .split(let axis, let ratio, let first, let second) = self else { return [] }
        let rects = Self.childRects(axis: axis, ratio: ratio, in: rect, gap: gap)
        return [Divider(path: path, axis: axis, frame: rects.divider, parent: rect, gap: gap)]
            + first.dividers(in: rects.first, gap: gap, path: path + [0])
            + second.dividers(in: rects.second, gap: gap, path: path + [1])
    }
}

// MARK: Codable

/// The keys match what the compiler wrote before `ratio` was optional, so old `state.json` files still decode.
extension SplitTree: Codable {
    private enum CodingKeys: String, CodingKey { case leaf, split }
    private enum LeafKeys: String, CodingKey { case _0 }
    private enum SplitKeys: String, CodingKey { case axis, ratio, first, second }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.leaf) {
            self = .leaf(try c.nestedContainer(keyedBy: LeafKeys.self, forKey: .leaf).decode(PaneID.self, forKey: ._0))
        } else if c.contains(.split) {
            let s = try c.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            let ratio = try s.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5
            self = .split(axis: try s.decode(SplitAxis.self, forKey: .axis), ratio: Self.clamp(ratio),
                          first: try s.decode(SplitTree.self, forKey: .first),
                          second: try s.decode(SplitTree.self, forKey: .second))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Neither leaf nor split"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id):
            var l = c.nestedContainer(keyedBy: LeafKeys.self, forKey: .leaf)
            try l.encode(id, forKey: ._0)
        case .split(let axis, let ratio, let first, let second):
            var s = c.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            try s.encode(axis, forKey: .axis)
            try s.encode(ratio, forKey: .ratio)
            try s.encode(first, forKey: .first)
            try s.encode(second, forKey: .second)
        }
    }
}
