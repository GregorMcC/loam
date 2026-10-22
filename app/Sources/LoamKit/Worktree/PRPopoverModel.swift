import CoreGraphics
import Foundation
import Observation

/// Where a popover opens from (ticket 109).
public enum PopoverAnchor: Equatable, Sendable {
    /// A control that was clicked: its rectangle in the window, as AppKit reports it (the origin is the
    /// bottom left corner of the window). The window turns it into the space of the overlay.
    case windowRect(CGRect)
    /// A key, ⌘⇧L or the switcher opened the popover, so no control was clicked. It sits over the left
    /// end of the action bar, where the chip of the PR is.
    case actionBar
}

/// The open PR popover (ticket 109): which worktree it shows, where it opens from, and what its buttons
/// are doing. `AppModel` owns one, opens it (`openPullRequest`), and runs the buttons. The row that the
/// popover shows is never kept here: the view reads it from `AppModel.worktreeStatus`, so a refresh of
/// the ship state changes the open popover.
///
/// Each open has a number (`openCount`). An answer that comes after the popover closed or opened again
/// carries the number of its own open and is dropped, so it cannot show in the wrong popover.
@MainActor @Observable
public final class PRPopoverModel {
    /// The worktree that the popover shows. Nil while it is closed.
    public private(set) var worktreeID: String?
    public private(set) var anchor: PopoverAnchor = .actionBar
    /// Counts the opens, so the view can focus itself on each one.
    public private(set) var openCount = 0
    /// True while the refresh of this open runs (`loam worktree list --refresh --worktree`).
    public private(set) var isRefreshing = false
    /// When GitHub answered the refresh of this open. Nil until it does, and when the refresh failed.
    public private(set) var answeredAt: Date?
    /// The button that runs now.
    public private(set) var running: PRSecondaryAction?
    /// What the last button did, or why it failed. It goes when the popover opens again.
    public private(set) var note: String?
    /// Called when the popover opens or closes. A new open while it is open calls nothing.
    @ObservationIgnored public var onOpenChange: ((Bool) -> Void)?

    public var isOpen: Bool { worktreeID != nil }

    public init() {}

    /// Opens for `id`, or moves an open popover to `id`. Returns the number of this open.
    func open(_ id: String, anchor: PopoverAnchor) -> Int {
        let wasOpen = isOpen
        worktreeID = id
        self.anchor = anchor
        openCount += 1
        isRefreshing = true
        answeredAt = nil
        running = nil
        note = nil
        if !wasOpen { onOpenChange?(true) }
        return openCount
    }

    /// Closes the popover and forgets what this open learned. Does nothing when it is closed.
    public func close() {
        guard isOpen else { return }
        worktreeID = nil
        isRefreshing = false
        answeredAt = nil
        running = nil
        note = nil
        onOpenChange?(false)
    }

    /// True while `open` is the open that stands.
    func isCurrent(_ open: Int) -> Bool { isOpen && open == openCount }

    /// The refresh of `open` ended. `answeredAt` is nil when it failed.
    func endRefresh(of open: Int, answeredAt: Date?) {
        guard isCurrent(open) else { return }
        isRefreshing = false
        self.answeredAt = answeredAt
    }

    /// Shows a line under the buttons, such as "Copied the branch name." It goes when the popover opens again.
    public func say(_ line: String) {
        guard isOpen else { return }
        note = line
    }

    /// A refresh of `open` starts again, after a button changed the PR.
    func beginRefresh(of open: Int) {
        guard isCurrent(open) else { return }
        isRefreshing = true
        answeredAt = nil
    }

    /// A button starts. False when the open is old or another button runs, so one command runs at a time.
    func begin(_ action: PRSecondaryAction, in open: Int) -> Bool {
        guard isCurrent(open), running == nil else { return false }
        running = action
        note = nil
        return true
    }

    /// The button ended, with a note for the person.
    func end(_ open: Int, note: String) {
        guard isCurrent(open) else { return }
        running = nil
        self.note = note
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
