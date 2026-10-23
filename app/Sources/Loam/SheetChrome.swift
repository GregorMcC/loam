import AppKit
import LoamKit
import SwiftUI

// The chrome of a sheet over the window: a dim scrim and a card on `horizon-a` with `radius-lg` and `shadow-switcher`
// (ticket 112, boards 3.1 to 3.3). The Land sheet and the New worktree sheet (ticket 115) use it. The footer buttons are
// native: Cancel is `loamSecondaryButton()` and the primary button is `loamPrimaryButton()`, both at the large size
// (ticket 120). The sheets and the PR popover move the keys on Tab themselves (ticket 123). Each overlay gives the keys to a
// control when it opens (`WindowRef.giveKeysToAControl`, ticket 130).

extension WindowRef {
    /// True when a control in the hosting view `Host` has the keys: the first responder is in that hosting view and is not
    /// the hosting view itself. A card that has the keys counts, because SwiftUI gives them to a view in the hosting view.
    func controlHasTheKeys<Host: NSView>(in host: Host.Type) -> Bool {
        var view = (window ?? NSApp.keyWindow)?.firstResponder as? NSView
        if view is Host { return false }
        while let current = view {
            if current is Host { return true }
            view = current.superview
        }
        return false
    }

    /// Gives the keys to a control of an overlay that opened in the hosting view `Host` (ticket 130). The opener gives the
    /// keys to the hosting view. Then `focus(true)` asks SwiftUI to move them to the control, with a `@FocusState` write.
    /// SwiftUI takes a write at its next update, so the tries are 30 ms apart. They stop when the overlay closes or a control
    /// has the keys. A write after that point does nothing useful, and a close can come before SwiftUI takes it.
    @MainActor
    func giveKeysToAControl<Host: NSView>(of host: Host.Type, while isOpen: () -> Bool, isFocused: () -> Bool,
                                          focus: (Bool) -> Void) async {
        await clearALeftFocus(of: host, isFocused: isFocused()) { focus(false) }
        for attempt in 0..<5 {
            guard isOpen() else { return }
            if attempt > 0, controlHasTheKeys(in: host) { return }
            focus(true)
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// Clears a focus that is left from a refused move, before an overlay in the hosting view `Host` asks for the keys.
    /// After a close, `MainWindow` refuses the late move into the hidden overlay. SwiftUI then still thinks that a
    /// control has the keys, and a write of the same value does nothing. So when `isFocused` is true and no control has
    /// the keys, `clear` runs, and SwiftUI takes it before the next write.
    @MainActor
    func clearALeftFocus<Host: NSView>(of host: Host.Type, isFocused: Bool, clear: () -> Void) async {
        guard isFocused, !controlHasTheKeys(in: host) else { return }
        clear()
        try? await Task.sleep(for: .milliseconds(30))
    }
}

/// The dim layer behind a sheet. A click on it closes the sheet. It stops under the title bar: the toolbar draws over the
/// overlays of the window, and `TitleBarScrim` dims the title bar (ticket 126).
struct SheetScrim: View {
    var arrived: Bool
    var close: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Color(nsColor: LoamTheme.scrim)
            .opacity(LoamTheme.scrimAlpha(dark: scheme == .dark))
            .ignoresSafeArea(edges: [.bottom, .horizontal])
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
    /// goes no further, so it never leaves the overlay. With keyboard navigation on, each control is a stop, and AppKit moves
    /// the keys as macOS sets it. A Tab during input method composition is the input method's.
    func overlayTabKeys(composing: @escaping () -> Bool, move: @escaping (_ back: Bool) -> Void) -> some View {
        onKeyPress(keys: [.tab, .backTab], phases: [.down, .repeat]) { press in
            guard !NSApp.isFullKeyboardAccessEnabled, !composing() else { return .ignored }
            move(press.key == .backTab || press.modifiers.contains(.shift))
            return .handled
        }
    }
}

private extension KeyEquivalent {
    /// Shift-Tab, as AppKit reports it: the back tab character.
    static let backTab = KeyEquivalent("\u{19}")
}
