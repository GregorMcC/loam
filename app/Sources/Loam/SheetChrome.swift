import LoamKit
import SwiftUI

// The chrome of a sheet over the window: a dim scrim and a card on `horizon-a` with `radius-lg` and `shadow-switcher`
// (ticket 112, boards 3.1 to 3.3). The Land sheet and the New worktree sheet (ticket 115) use it. The footer buttons are
// native: Cancel is `loamSecondaryButton()` and the primary button is `loamPrimaryButton()`, both at the large size
// (ticket 120).

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

extension View {
    /// The card of a sheet: padding, `width`, and `horizon-a` with `radius-lg` and each layer of `shadow-switcher`.
    func sheetCard(width: CGFloat) -> some View {
        padding(EdgeInsets(top: 20, leading: 20, bottom: 18, trailing: 20))
            .frame(width: width)
            .loamFloating(.switcher, ground: LoamColor.horizonA, radius: LoamTheme.radiusLg)
    }
}
