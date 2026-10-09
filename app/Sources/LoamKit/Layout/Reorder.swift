import Foundation

/// The geometry of a drag that reorders items along one axis (ticket 98): the tabs along the tab
/// bar, and the plots down one section of the sidebar. Each item has a start and a length on the
/// axis, in order, with `spacing` between two items. It holds no state, so tests cover every rule.
public struct Reorder: Equatable, Sendable {
    public var starts: [Double]
    public var lengths: [Double]
    public var spacing: Double
    /// The index of the item that you drag.
    public var dragged: Int

    public init(starts: [Double], lengths: [Double], spacing: Double = 0, dragged: Int) {
        precondition(starts.count == lengths.count && starts.indices.contains(dragged))
        self.starts = starts
        self.lengths = lengths
        self.spacing = spacing
        self.dragged = dragged
    }

    public var count: Int { starts.count }

    private func mid(_ index: Int) -> Double { starts[index] + lengths[index] / 2 }

    /// The index where the dragged item lands with the pointer at `pointer`. An item after the
    /// dragged one gives up its slot once the pointer passes its midpoint, and an item before it the same.
    public func slot(pointer: Double) -> Int {
        let after = (dragged + 1..<count).filter { pointer > mid($0) }.count
        let before = (0..<dragged).filter { pointer < mid($0) }.count
        return dragged + after - before
    }

    /// The index where the dragged item lands when it starts at `start` on the axis. An item after
    /// it gives up its slot once the dragged item's far edge passes the item's midpoint, and an item
    /// before it once the near edge does. So a tall item, such as an open plot with its tree, lands
    /// where it shows, wherever you hold it.
    public func slot(start: Double) -> Int {
        let end = start + lengths[dragged]
        let after = (dragged + 1..<count).filter { end > mid($0) }.count
        let before = (0..<dragged).filter { start < mid($0) }.count
        return dragged + after - before
    }

    /// How far item `index` moves aside while the dragged item waits at `slot`. The dragged item
    /// itself gets 0: it follows the pointer.
    public func offset(of index: Int, slot: Int) -> Double {
        let shift = lengths[dragged] + spacing
        if index > dragged, index <= slot { return -shift }
        if index < dragged, index >= slot { return shift }
        return 0
    }

    /// The offset from its start at which the dragged item settles into `slot`.
    public func settleOffset(slot: Int) -> Double {
        if slot > dragged { return (dragged + 1...slot).reduce(0) { $0 + lengths[$1] + spacing } }
        if slot < dragged { return -(slot..<dragged).reduce(0) { $0 + lengths[$1] + spacing } }
        return 0
    }

    /// Where the insertion line goes for `slot` under Reduce Motion: halfway into the spacing
    /// before or after the item whose place it takes. Nil when the slot is where the item started.
    public func insertionPoint(slot: Int) -> Double? {
        if slot < dragged { return starts[slot] - spacing / 2 }
        if slot > dragged { return starts[slot] + lengths[slot] + spacing / 2 }
        return nil
    }
}
