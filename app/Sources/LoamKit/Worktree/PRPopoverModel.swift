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
        onOpenChange?(false)
    }

    /// Shows a line under the buttons, such as "Copied the branch name." It goes when the popover opens again.
    public func say(_ line: String) {
        guard isOpen else { return }
        note = line
    }

    // MARK: Refresh

    func beginRefresh(of id: String) {
        refreshing.insert(id)
    }

    /// The refresh of `id` ended. `answered` is false when the core gave no answer.
    func endRefresh(of id: String, answered: Bool, at date: Date = Date()) {
        refreshing.remove(id)
        guard worktreeID == id else { return }
        attemptedAt = answered ? date : nil
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

    /// Below the anchor when it fits, else above. When it fits on neither side, on the side with more room.
    /// It stays inside the container, and at the top and the left edge when the container is too small.
    public static func frame(size: CGSize, anchor: CGRect, in container: CGRect) -> CGRect {
        let below = container.maxY - margin - anchor.maxY - gap
        let above = anchor.minY - gap - margin - container.minY
        let opensBelow = size.height <= below || (size.height > above && below >= above)
        let y = opensBelow ? anchor.maxY + gap : anchor.minY - gap - size.height
        return CGRect(origin: CGPoint(x: clamp(anchor.minX, size.width, container.minX, container.maxX),
                                      y: clamp(y, size.height, container.minY, container.maxY)), size: size)
    }

    private static func clamp(_ start: CGFloat, _ length: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low + margin, min(start, high - margin - length))
    }
}
