import AppKit
import LoamKit
import SwiftUI

// The chrome of a sheet over the window: a dim scrim and a card on `horizon-a` with `radius-lg` and `shadow-switcher`
// (ticket 112, boards 3.1 to 3.3). The Land sheet and the New worktree sheet (ticket 115) use it. The footer buttons are
// native: Cancel is `loamSecondaryButton()` and the primary button is `loamPrimaryButton()`, both at the large size
// (ticket 120). The sheets and the PR popover move the keys on Tab themselves (ticket 123).

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

extension View {
    /// Tab and Shift-Tab in a sheet or a popover over the window (ticket 123). SwiftUI gives the root view of the overlay the
    /// Tab of a text field too. `move` gets true for Shift-Tab and moves the keys to the next stop (`TabStops`). The key then
    /// goes no further, so it never leaves the overlay. `move` returns false when it does not know where the keys are, and
    /// AppKit moves them. With keyboard navigation on, each control is a stop, so AppKit keeps the order. A Tab during input
    /// method composition is the input method's.
    func overlayTabKeys(composing: @escaping () -> Bool, move: @escaping (_ back: Bool) -> Bool) -> some View {
        onKeyPress(keys: [.tab, .backTab], phases: [.down, .repeat]) { press in
            guard !NSApp.isFullKeyboardAccessEnabled, !composing() else { return .ignored }
            return move(press.key == .backTab || press.modifiers.contains(.shift)) ? .handled : .ignored
        }
    }
}

private extension KeyEquivalent {
    /// Shift-Tab, as AppKit reports it: the back tab character.
    static let backTab = KeyEquivalent("\u{19}")
}
