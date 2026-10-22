import CoreGraphics
import Foundation
import Observation

/// A control that a popover opens from (ticket 109). It says where it is now, so the popover can follow it
/// when the window, a divider or a column moves it.
@MainActor
public protocol PopoverAnchorControl: AnyObject, Sendable {
    /// The rectangle of the control in its window, as AppKit reports it (the origin is the bottom left
    /// corner of the window). Nil when the control is gone: out of the window, hidden, or out of view.
    var windowRect: CGRect? { get }
}

/// Where a popover opens from (ticket 109).
public enum PopoverAnchor: Equatable, Sendable {
    /// A control that was clicked. The window asks it where it is each time it places the popover, and
    /// closes the popover when the control is gone.
    case control(any PopoverAnchorControl)
    /// The chip of the action bar, or no control: a key, ⌘⇧L or the switcher opened the popover. It sits at
    /// the chip when the chip shows the PR of the popover, else over the left end of the action bar.
    case actionBar

    /// Two controls are the same anchor only when they are the same object.
    public static func == (lhs: PopoverAnchor, rhs: PopoverAnchor) -> Bool {
        switch (lhs, rhs) {
        case (.control(let left), .control(let right)): left === right
        case (.actionBar, .actionBar): true
        default: false
        }
    }
}

/// The open PR popover (ticket 109): which worktree it shows, where it opens from, and what runs for
/// it. `AppModel` owns one, opens it (`openPullRequest`), and runs the buttons. The row that the popover
/// shows is never kept here: the view reads it from `AppModel.worktreeStatus`, so a refresh of the ship
/// state changes the open popover.
///
/// A refresh and a button belong to their worktree, not to one open. They go on when the popover closes or
/// shows another worktree, and a popover that opens again on the worktree shows them still running. Their
/// answers show only while the popover shows that worktree.
@MainActor @Observable
public final class PRPopoverModel {
    /// The worktree that the popover shows. Nil while it is closed.
    public private(set) var worktreeID: String?
    public private(set) var anchor: PopoverAnchor = .actionBar
    /// Counts the opens, so the view can focus itself on each one.
    public private(set) var openCount = 0
    /// When the core last answered a refresh of the shown worktree in this open, with GitHub reached or not.
    /// The offline line names it as the time of the attempt. Nil until the core answers, and after a refresh
    /// that got no answer from the core.
    public private(set) var attemptedAt: Date?
    /// What the last button did, or why it failed. It goes when the popover opens again.
    public private(set) var note: String?
    /// True while the passed checks show in the card (ticket 116). The list is closed on each open, because each
    /// open is a new card. A refresh and a button leave it as it is.
    public private(set) var showsPassedChecks = false
    /// The worktrees whose refresh runs now (`AppModel.refreshWorktree`), shown or not.
    private var refreshing: Set<String> = []
    /// The button that runs for each worktree. One runs at a time for a worktree.
    private var buttons: [String: PRSecondaryAction] = [:]
    /// Called when the popover opens or closes. A new open while it is open calls nothing.
    @ObservationIgnored public var onOpenChange: ((Bool) -> Void)?
    /// Called after each open, also one that moves an open popover to another worktree or control, so the
    /// window places the popover at its control before it draws.
    @ObservationIgnored public var onOpen: (() -> Void)?

    public var isOpen: Bool { worktreeID != nil }
    /// True while the shown worktree refreshes (`loam worktree list --refresh --worktree`).
    public var isRefreshing: Bool { worktreeID.map(refreshing.contains) ?? false }
    /// The button that runs for the shown worktree.
    public var running: PRSecondaryAction? { worktreeID.flatMap { buttons[$0] } }

    public init() {}

    /// Opens for `id`, or moves an open popover to `id`.
    func open(_ id: String, anchor: PopoverAnchor) {
        let wasOpen = isOpen
        worktreeID = id
        self.anchor = anchor
        openCount += 1
        attemptedAt = nil
        note = nil
        showsPassedChecks = false
        if !wasOpen { onOpenChange?(true) }
        onOpen?()
    }

    /// Closes the popover and forgets what this open learned. A refresh or a button that runs goes on.
    /// Does nothing when it is closed.
    public func close() {
        guard isOpen else { return }
        worktreeID = nil
        attemptedAt = nil
        note = nil
        showsPassedChecks = false
        onOpenChange?(false)
    }

    /// Shows a line under the buttons, such as "Copied the branch name." It goes when the popover opens again.
    public func say(_ line: String) {
        guard isOpen else { return }
        note = line
    }

    /// Opens the passed checks in the card, or closes them. Does nothing when the popover is closed.
    public func togglePassedChecks() {
        guard isOpen else { return }
        showsPassedChecks.toggle()
    }

    /// Closes the passed checks because their row went away: a refresh found no failed check. A row that comes
    /// back later shows the list closed.
    public func hidePassedChecks() {
        showsPassedChecks = false
    }

    // MARK: Refresh

    /// A refresh of `id` starts.
    func beginRefresh(of id: String) {
        refreshing.insert(id)
    }

    /// The refresh of `id` ended. `answered` is false when the core gave no answer.
    func endRefresh(of id: String, answered: Bool) {
        refreshing.remove(id)
        guard worktreeID == id else { return }
        attemptedAt = answered ? Date() : nil
    }

    // MARK: Buttons

    /// A button starts for `id`. False while a button runs for that worktree, so one command runs at a time.
    func begin(_ action: PRSecondaryAction, for id: String) -> Bool {
        guard buttons[id] == nil else { return false }
        buttons[id] = action
        if worktreeID == id { note = nil }
        return true
    }

    /// The button of `id` ended, with a note for the person. Returns false when the popover does not show
    /// the worktree now, so nobody sees the note.
    @discardableResult
    func end(_ id: String, note: String) -> Bool {
        buttons[id] = nil
        guard worktreeID == id else { return false }
        self.note = note
        return true
    }
}

/// Where a popover of `size` goes, in the space of its container (the origin is the top left corner).
public enum PopoverPlacement {
    /// The room between the anchor and the popover.
    public static let gap: CGFloat = 6
    /// The room that the popover keeps to each edge of the container.
    public static let margin: CGFloat = 8

    /// The side of the anchor that a popover stands on.
    public enum Side: Equatable, Sendable {
        case below
        case above
    }

    /// The tallest popover that fits the container: it keeps its margin at the top and at the bottom.
    public static func maxHeight(in container: CGRect) -> CGFloat {
        max(0, container.height - 2 * margin)
    }

    /// Below the anchor when it fits, else above. When it fits on neither side, on the side with more room.
    public static func side(size: CGSize, anchor: CGRect, in container: CGRect) -> Side {
        let below = container.maxY - margin - anchor.maxY - gap
        let above = anchor.minY - gap - margin - container.minY
        return size.height <= below || (size.height > above && below >= above) ? .below : .above
    }

    /// The frame on `side` of the anchor. It stays inside the container, and at the top and the left edge
    /// when the container is too small. A popover that is too tall for its side stays on it and moves only as far
    /// as it needs to stay inside, so it does not jump to the other side.
    public static func frame(size: CGSize, anchor: CGRect, side: Side, in container: CGRect) -> CGRect {
        let y = side == .below ? anchor.maxY + gap : anchor.minY - gap - size.height
        return CGRect(origin: CGPoint(x: clamp(anchor.minX, size.width, container.minX, container.maxX),
                                      y: clamp(y, size.height, container.minY, container.maxY)), size: size)
    }

    /// The frame on the side that `side(size:anchor:in:)` picks for a new popover.
    public static func frame(size: CGSize, anchor: CGRect, in container: CGRect) -> CGRect {
        frame(size: size, anchor: anchor, side: side(size: size, anchor: anchor, in: container), in: container)
    }

    private static func clamp(_ start: CGFloat, _ length: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low + margin, min(start, high - margin - length))
    }
}

/// What the window knows of the card of the open PR popover: the side of its control that it stands on (ticket 116).
/// With its passed list closed, the card takes the side that `PopoverPlacement.side(size:anchor:in:)` picks on each
/// layout, as in ticket 109. A list that opens makes the card taller, and the card keeps the side it had while the
/// list is open, so it does not jump over its control to the other side.
public struct PopoverMeasure: Equatable, Sendable {
    private var open = 0
    private var side = PopoverPlacement.Side.below

    public init() {}

    /// The side for the card of open number `open`, when the card is `size` and its control is at `anchor`. With the
    /// list closed, the side is the one that the rule picks for this size. With the list open, it is the side from
    /// the last layout with the list closed. A new open picks again, because each open is a new card.
    public mutating func measure(_ size: CGSize, open: Int, listOpen: Bool, anchor: CGRect, in container: CGRect) -> PopoverPlacement.Side {
        if self.open != open || !listOpen { side = PopoverPlacement.side(size: size, anchor: anchor, in: container) }
        self.open = open
        return side
    }
}
