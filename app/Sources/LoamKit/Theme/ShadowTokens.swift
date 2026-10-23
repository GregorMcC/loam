import AppKit

/// One layer of a shadow token (docs/design/tokens.json), as CSS writes it: an offset, a blur, a spread and a colour. An
/// `inset` layer is a light line inside the top edge of the card, not a shadow under it.
public struct ShadowLayer: Equatable, Sendable {
    public var inset: Bool
    public var x: CGFloat
    public var y: CGFloat
    public var blur: CGFloat
    public var spread: CGFloat
    /// The colour as 0xRRGGBB.
    public var rgb: UInt32
    public var alpha: CGFloat

    public init(inset: Bool = false, x: CGFloat = 0, y: CGFloat, blur: CGFloat, spread: CGFloat = 0, rgb: UInt32, alpha: UInt8) {
        self.inset = inset
        self.x = x
        self.y = y
        self.blur = blur
        self.spread = spread
        self.rgb = rgb
        self.alpha = CGFloat(alpha) / 255
    }

    /// The radius that SwiftUI and Core Animation take: half the CSS blur.
    public var radius: CGFloat { blur / 2 }

    /// The colour with its alpha.
    public var color: NSColor { LoamTheme.srgb(rgb).withAlphaComponent(alpha) }
}

extension LoamTheme {
    /// The two shadow tokens. Only things that float over the panes cast a shadow (docs/design, Depth and shadow).
    public enum ShadowToken: String, CaseIterable, Sendable {
        /// Popovers and menus on `horizon-b`.
        case raised = "shadow-raised"
        /// The quick switcher and sheets.
        case switcher = "shadow-switcher"
    }

    /// Every layer of a shadow token, in the order of the CSS: Night for `dark`, else Day. A view draws each layer, so the
    /// contact layer of Day and the light line of Night show too. `ShadowTokenTests` checks the layers against the JSON.
    public static func shadow(_ token: ShadowToken, dark: Bool) -> [ShadowLayer] {
        switch (token, dark) {
        case (.raised, true):
            [ShadowLayer(inset: true, y: 1, blur: 0, rgb: 0xffffff, alpha: 0x0d),
             ShadowLayer(y: 1, blur: 3, rgb: 0x000000, alpha: 0x80),
             ShadowLayer(y: 8, blur: 24, rgb: 0x000000, alpha: 0x8c)]
        case (.raised, false):
            [ShadowLayer(y: 1, blur: 2, rgb: 0x2a2014, alpha: 0x18),
             ShadowLayer(y: 8, blur: 24, rgb: 0x2a2014, alpha: 0x24)]
        case (.switcher, true):
            [ShadowLayer(inset: true, y: 1, blur: 0, rgb: 0xffffff, alpha: 0x12),
             ShadowLayer(y: 2, blur: 6, rgb: 0x000000, alpha: 0x99),
             ShadowLayer(y: 24, blur: 64, rgb: 0x000000, alpha: 0xcc)]
        case (.switcher, false):
            [ShadowLayer(y: 2, blur: 6, rgb: 0x2a2014, alpha: 0x1f),
             ShadowLayer(y: 24, blur: 64, rgb: 0x2a2014, alpha: 0x38)]
        }
    }
}
