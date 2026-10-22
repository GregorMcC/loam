import LoamKit
import SwiftUI

// The chrome of a sheet over the window (ticket 115): a dim scrim and a card on `horizon-a` with `radius-lg` and
// `shadow-switcher`, as the Land sheet draws them (ticket 112, boards 3.1 to 3.3). The New worktree sheet uses it.

/// The dim layer behind a sheet. A click on it closes the sheet.
struct SheetScrim: View {
    var arrived: Bool
    var close: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Color(nsColor: LoamTheme.scrim)
            .opacity(LoamTheme.scrimAlpha(dark: scheme == .dark))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .opacity(arrived ? 1 : 0)
            .accessibilityHidden(true)
    }
}

private struct SheetCard: ViewModifier {
    let width: CGFloat
    @Environment(\.colorScheme) private var scheme
    private static let radius = LoamTheme.radiusLg

    func body(content: Content) -> some View {
        content
            .padding(EdgeInsets(top: 20, leading: 20, bottom: 18, trailing: 20))
            .frame(width: width)
            .background(LoamColor.horizonA, in: RoundedRectangle(cornerRadius: Self.radius))
            .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(LoamColor.inkHairline))
            // Night has a light line inside the top edge (`shadow-switcher`).
            .overlay(alignment: .top) {
                Color.white.opacity(LoamTheme.shadowSwitcherEdgeAlpha(dark: scheme == .dark))
                    .frame(height: 1)
                    .padding(.horizontal, Self.radius)
                    .allowsHitTesting(false)
            }
            .shadow(color: Color(nsColor: LoamTheme.shadowSwitcher).opacity(LoamTheme.shadowSwitcherAlpha(dark: scheme == .dark)),
                    radius: 32, y: 24)
    }
}

extension View {
    /// The card of a sheet: padding, `width`, the ground, the border and the shadow.
    func sheetCard(width: CGFloat) -> some View { modifier(SheetCard(width: width)) }
}

/// Cancel (the `.bc` of the boards): 28 pt high, radius 6, a fill and an `edge` border.
struct SheetCancelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(LoamColor.ink)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(configuration.isPressed ? LoamColor.inkSelected : LoamColor.inkFill, in: shape)
            .overlay(shape.strokeBorder(LoamColor.edge))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(shape)
    }
}
