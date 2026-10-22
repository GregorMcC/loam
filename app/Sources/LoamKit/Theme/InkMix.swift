import AppKit

/// Hairlines and fills mixed from the ink (polish README): soft structure that follows the
/// terminal theme, because the ink follows it (`ChromePalette`).
extension LoamTheme {
    /// A hairline: the edge of the well, the line under the tab bar, a pane header line.
    public static let hairlineAlpha: CGFloat = 0.08
    /// The fill of a hovered row or tab.
    public static let hoverFillAlpha: CGFloat = 0.05
    /// The fill of a selected row or tab.
    public static let selectedFillAlpha: CGFloat = 0.09
    /// The fill of a keycap.
    public static let keycapFillAlpha: CGFloat = 0.10

    /// The ink at `alpha`, for the appearance it resolves in.
    public static func inkAlpha(_ alpha: CGFloat, palette: ChromePalette = .shared) -> NSColor {
        let ink = inkColor(palette)
        return NSColor(name: nil) { appearance in
            var resolved = ink
            appearance.performAsCurrentDrawingAppearance { resolved = ink.usingColorSpace(.sRGB) ?? ink }
            return resolved.withAlphaComponent(alpha)
        }
    }

    /// The ink at `alpha` over `base`, as one opaque color. Use it where a line must not let the
    /// window through (a divider between panes).
    public static func inkOver(_ base: NSColor, alpha: CGFloat, palette: ChromePalette = .shared) -> NSColor {
        let ink = inkColor(palette)
        return NSColor(name: nil) { appearance in
            var b = base, i = ink
            appearance.performAsCurrentDrawingAppearance {
                b = base.usingColorSpace(.sRGB) ?? base
                i = ink.usingColorSpace(.sRGB) ?? ink
            }
            func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * alpha }
            return NSColor(srgbRed: mix(b.redComponent, i.redComponent), green: mix(b.greenComponent, i.greenComponent),
                           blue: mix(b.blueComponent, i.blueComponent), alpha: 1)
        }
    }

    /// The `ink` token for `palette`.
    private static func inkColor(_ palette: ChromePalette) -> NSColor {
        guard palette !== ChromePalette.shared, let token = colorTokens.first(where: { $0.name == "ink" }) else { return ink }
        return surface("ink", night: token.night, day: token.day, palette: palette)
    }

    /// The color of `shadow-raised` (docs/design/tokens.json): popovers and menus on `horizon-b`.
    /// The blur is 24 and the drop 8.
    public static let shadowRaised = dynamic(night: 0x000000, day: 0x2a2014)
    public static func shadowRaisedAlpha(dark: Bool) -> CGFloat { dark ? 0x66 / 255 : 0x24 / 255 }

    /// The color of `shadow-switcher` (docs/design/tokens.json): the quick switcher and sheets. The blur is 64 and the
    /// drop 24. Night also has a 1 pt light line at the top edge (`shadowSwitcherEdgeAlpha`).
    public static let shadowSwitcher = dynamic(night: 0x000000, day: 0x2a2014)
    public static func shadowSwitcherAlpha(dark: Bool) -> CGFloat { dark ? 0xa6 / 255 : 0x38 / 255 }
    /// The light line inside the top edge of a sheet in Night: white at 7%. Day has none.
    public static func shadowSwitcherEdgeAlpha(dark: Bool) -> CGFloat { dark ? 0x12 / 255 : 0 }

    /// The dim behind a sheet (board 3.1): the ground of the window at 55% in Night, and the brown of the day shadow at
    /// 28% in Day.
    public static let scrim = dynamic(night: 0x080706, day: 0x2a2014)
    public static func scrimAlpha(dark: Bool) -> CGFloat { dark ? 0.55 : 0.28 }

    /// The hairline with the shared palette.
    public static var hairline: NSColor { inkAlpha(hairlineAlpha) }
}
