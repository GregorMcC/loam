import AppKit

/// A tab bar view that reports where its first tab sits. The driver reads it without the app target,
/// to check that no tab sits under the window buttons (bug 63). The toolbar of ticket 69 holds the
/// buttons in its own row above the bar, so the bar needs no inset.
@MainActor
public protocol FirstTabFraming: NSView {
    /// The first tab's frame in the view's own coordinates.
    var firstTabFrame: CGRect? { get }
}
