import Foundation

/// The terminal well (ticket 88): the tab bar and the panes sit in one rounded card, inset in the
/// window frame. A margin of frame shows above it, under the toolbar, and on each side where no
/// sidebar or plot panel touches it.
public enum WellLayout {
    public struct Insets: Equatable, Sendable {
        public var top: CGFloat
        public var left: CGFloat
        public var bottom: CGFloat
        public var right: CGFloat

        public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }
    }

    /// The frame that shows around the well.
    public static let margin: CGFloat = 8
    /// The corner radius of the card.
    public static let cornerRadius: CGFloat = 12
    /// The frame under the well when nothing else takes the bottom edge.
    public static let bottomMargin: CGFloat = margin

    /// The insets of the well in the middle column. `bottom` is the room under the well: the
    /// margin, or the height of a row that stands under it.
    public static func insets(sidebarShown: Bool, panelShown: Bool, bottom: CGFloat = bottomMargin) -> Insets {
        Insets(top: margin, left: sidebarShown ? 0 : margin, bottom: bottom, right: panelShown ? 0 : margin)
    }
}
