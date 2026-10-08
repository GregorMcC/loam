import AppKit

/// A tab bar view that reports where its first tab sits. The driver reads it without the app target,
/// to check that no tab sits under the window buttons (bug 63). The toolbar of ticket 69 holds the
/// buttons in its own row above the bar, so the bar needs no inset.
@MainActor
public protocol FirstTabFraming: NSView {
    /// The first tab's frame in the view's own coordinates.
    var firstTabFrame: CGRect? { get }
    /// The frame of the tab at a 0-based position, in the view's own coordinates. The driver
    /// hovers and clicks tabs with it (ticket 96).
    func tabFrame(at index: Int) -> CGRect?
}
