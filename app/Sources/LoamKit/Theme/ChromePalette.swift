import AppKit
import Foundation

/// The chrome colors that follow the terminal theme (tickets 68 and 70). `bedrock` is the
/// terminal background. The horizons and `rule` take the same lightness steps from it that
/// Loam's own tokens take from Loam's `bedrock`, in OKLCH, with the hue and chroma of the
/// background. Night (a dark background) steps lighter. Day (a light one) steps darker.
///
/// The ink takes a low-chroma tint of the background hue. The four text-bearing state hues
/// (`moss`, `needs-you`, `done-unread`, `rust`) keep their hue and chroma. Every text color moves
/// in lightness only, and only as far as it needs to reach its contrast on the text surfaces.
/// The wash tokens, `edge`, and `focus` do not change.
public struct ChromeSurfaces: Sendable, Equatable {
    public var bedrock: UInt32
    public var horizonO: UInt32
    public var horizonA: UInt32
    public var horizonB: UInt32
    public var rule: UInt32
    /// The ground behind the glass sidebar and the toolbar row. Night: `bedrock`. Day: `horizon-o`,
    /// so the glass edge shows.
    public var frame: UInt32
    public var ink: UInt32
    public var inkMuted: UInt32
    public var inkFaint: UInt32
    public var moss: UInt32
    public var needsYou: UInt32
    public var doneUnread: UInt32
    public var rust: UInt32
    /// True for a Night set: the background is dark.
    public var isDark: Bool

    /// The token names that follow the terminal.
    public static let tokenNames = [
        "bedrock", "horizon-o", "horizon-a", "horizon-b", "rule", "frame",
        "ink", "ink-muted", "ink-faint", "moss", "needs-you", "done-unread", "rust",
    ]

    public func value(of token: String) -> UInt32? {
        switch token {
        case "bedrock": bedrock
        case "horizon-o": horizonO
        case "horizon-a": horizonA
        case "horizon-b": horizonB
        case "rule": rule
        case "frame": frame
        case "ink": ink
        case "ink-muted": inkMuted
        case "ink-faint": inkFaint
        case "moss": moss
        case "needs-you": needsYou
        case "done-unread": doneUnread
        case "rust": rust
        default: nil
        }
    }

    /// The surfaces that carry text: ink needs its contrast on each of them. `rule` and `frame` do not.
    public var textSurfaces: [UInt32] { [bedrock, horizonO, horizonA, horizonB] }

    /// Loam's own colors, from the tokens.
    public static let loamNight = fromTokens(dark: true)
    public static let loamDay = fromTokens(dark: false)

    private static func token(_ name: String, dark: Bool) -> UInt32 {
        let t = LoamTheme.colorTokens.first { $0.name == name }!
        return dark ? t.night : t.day
    }

    private static func fromTokens(dark: Bool) -> ChromeSurfaces {
        func t(_ name: String) -> UInt32 { token(name, dark: dark) }
        return ChromeSurfaces(
            bedrock: t("bedrock"), horizonO: t("horizon-o"), horizonA: t("horizon-a"), horizonB: t("horizon-b"),
            rule: t("rule"), frame: t("frame"), ink: t("ink"), inkMuted: t("ink-muted"), inkFaint: t("ink-faint"),
            moss: t("moss"), needsYou: t("needs-you"), doneUnread: t("done-unread"), rust: t("rust"), isDark: dark)
    }

    /// The OKLCH lightness steps from `bedrock` of Loam's tokens: Night, then Day.
    /// Night steps up. Day steps down, except `horizon-b`, which is a little lighter (raised).
    static let nightSteps = Steps(o: 0.0365, a: 0.0589, b: 0.0932, rule: 0.1538)
    static let daySteps = Steps(o: -0.0501, a: -0.0232, b: 0.0120, rule: -0.1222)

    struct Steps { let o, a, b, rule: Double }

    /// Chroma above this makes the chrome louder than the panes.
    static let maxChroma = 0.035
    /// The tint of the ink: the most chroma that `ink`, `ink-muted` and `ink-faint` take from the theme.
    static let maxInkChroma = 0.012
    /// Small text (`ink`, `ink-muted`, the state hues) reaches this on every text surface (WCAG AA).
    public static let textContrast = 4.5
    /// `ink-faint` labels (uppercase, 10.5px+) and placeholders reach this.
    public static let faintContrast = 3.0
    /// The most room that the chrome steps leave for pure black or white ink.
    static let inkRoom = 7.0

    /// The same rule as Ghostty's `window-theme = auto`: a background with a luma over 0.5 is light.
    public static func isDark(_ background: UInt32) -> Bool {
        let (r, g, b) = channels(background)
        return 0.299 * r + 0.587 * g + 0.114 * b <= 0.5
    }

    /// The colors for a terminal background. Loam's own `bedrock` gives Loam's own tokens.
    public static func derive(background: UInt32) -> ChromeSurfaces {
        if background == loamNight.bedrock { return loamNight }
        if background == loamDay.bedrock { return loamDay }
        let dark = isDark(background)
        let base = OKLCH(background)
        let steps = dark ? nightSteps : daySteps
        let chroma = min(base.c, maxChroma)
        func step(_ delta: Double) -> UInt32 {
            OKLCH(l: min(1, max(0, base.l + delta)), c: chroma, h: base.h).hex
        }
        func horizons(_ k: Double) -> (o: UInt32, a: UInt32, b: UInt32) {
            (step(steps.o * k), step(steps.a * k), step(steps.b * k))
        }
        // The steps start from the real lightness of the background, so each horizon sits on the
        // right side of `bedrock`. They shrink only when a step would leave less room than pure
        // ink needs on a text surface (a mid-tone background). `rule` is a hairline and keeps its step.
        let extreme: UInt32 = dark ? 0xffffff : 0x000000
        let required = min(inkRoom, contrast(extreme, background))
        func room(_ k: Double) -> Double {
            let h = horizons(k)
            return min(contrast(extreme, h.o), contrast(extreme, h.a), contrast(extreme, h.b))
        }
        var k = 1.0
        if room(1) < required {
            var lo = 0.0, hi = 1.0
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if room(mid) >= required { lo = mid } else { hi = mid }
            }
            k = lo
        }
        let h = horizons(k)
        let surfaces = [background, h.o, h.a, h.b]
        let rule = step(steps.rule)

        func tinted(_ name: String, ratio: Double) -> UInt32 {
            let l = OKLCH(token(name, dark: dark)).l
            return lift(OKLCH(l: l, c: min(base.c, maxInkChroma), h: base.h), dark: dark, ratio: ratio, on: surfaces)
        }
        func state(_ name: String) -> UInt32 {
            let hex = token(name, dark: dark)
            return lift(OKLCH(hex), dark: dark, ratio: textContrast, on: surfaces, keeping: hex)
        }
        return ChromeSurfaces(
            bedrock: background, horizonO: h.o, horizonA: h.a, horizonB: h.b, rule: rule,
            frame: dark ? background : h.o,
            ink: tinted("ink", ratio: textContrast), inkMuted: tinted("ink-muted", ratio: textContrast),
            inkFaint: tinted("ink-faint", ratio: faintContrast),
            moss: state("moss"), needsYou: state("needs-you"), doneUnread: state("done-unread"), rust: state("rust"),
            isDark: dark)
    }

    /// A text color at a start lightness, moved in lightness only (lighter on a dark surface, darker
    /// on a light one) until it reaches `ratio` on every surface. Hue and chroma stay. `keeping` is
    /// a hex value that is returned unchanged when it already reaches the ratio. When no lightness
    /// reaches it, the result is pure white or black.
    static func lift(_ start: OKLCH, dark: Bool, ratio: Double, on surfaces: [UInt32], keeping: UInt32? = nil) -> UInt32 {
        func worst(_ hex: UInt32) -> Double { surfaces.map { contrast(hex, $0) }.min() ?? 21 }
        if let keeping, worst(keeping) >= ratio { return keeping }
        var l = start.l
        while true {
            let hex = OKLCH(l: l, c: start.c, h: start.h).hex
            if worst(hex) >= ratio { return hex }
            if dark ? l >= 1 : l <= 0 { return dark ? 0xffffff : 0x000000 }
            l = dark ? min(1, l + 0.005) : max(0, l - 0.005)
        }
    }

    // MARK: Contrast

    /// The WCAG 2 contrast ratio of two sRGB colors: 1 to 21.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ hex: UInt32) -> Double {
        let (r, g, b) = channels(hex)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    static func channels(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
}

/// A color in OKLCH (Björn Ottosson's OKLab, in polar form). Lightness 0 to 1, hue in radians.
struct OKLCH: Equatable {
    var l: Double, c: Double, h: Double

    init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    init(_ hex: UInt32) {
        let (r, g, b) = ChromeSurfaces.channels(hex)
        let (lr, lg, lb) = (ChromeSurfaces.linear(r), ChromeSurfaces.linear(g), ChromeSurfaces.linear(b))
        let l1 = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m1 = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s1 = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        let L = 0.2104542553 * l1 + 0.7936177850 * m1 - 0.0040720453 * s1
        let a = 1.9779984951 * l1 - 2.4285922050 * m1 + 0.4505937099 * s1
        let bb = 0.0259040371 * l1 + 0.7827717662 * m1 - 0.8086757660 * s1
        self.init(l: L, c: (a * a + bb * bb).squareRoot(), h: atan2(bb, a))
    }

    /// The sRGB value. A color outside the gamut loses chroma, not hue: the chroma shrinks until
    /// every channel fits, so a dark or light state hue keeps its hue.
    var hex: UInt32 {
        func rgb(_ c: Double) -> (Double, Double, Double) {
            let a = c * cos(h), b = c * sin(h)
            let l1 = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m1 = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s1 = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
            return (4.0767416621 * l1 - 3.3077115913 * m1 + 0.2309699292 * s1,
                    -1.2684380046 * l1 + 2.6097574011 * m1 - 0.3413193965 * s1,
                    -0.0041960863 * l1 - 0.7034186147 * m1 + 1.7076147010 * s1)
        }
        func fits(_ v: (Double, Double, Double)) -> Bool {
            [v.0, v.1, v.2].allSatisfy { $0 >= -0.0005 && $0 <= 1.0005 }
        }
        var chroma = c
        if !fits(rgb(c)) {
            var lo = 0.0, hi = c
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if fits(rgb(mid)) { lo = mid } else { hi = mid }
            }
            chroma = lo
        }
        let (r, g, bl) = rgb(chroma)
        func byte(_ v: Double) -> UInt32 { UInt32((min(1, max(0, ChromeSurfaces.gamma(v))) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(bl)
    }
}

/// The chrome colors in use. The app sets them from the terminal background on each Ghostty
/// config change. Nil, or a set for the other appearance, gives Loam's own tokens. The surface
/// colors of `LoamTheme` read `shared` each time they resolve, on any thread.
public final class ChromePalette: @unchecked Sendable {
    public static let shared = ChromePalette()

    /// Posted, with the palette as the object, after `follow` changes the surfaces. An AppKit view
    /// observes it through `NSView.observeChromePalette`. It posts before the window appearance
    /// changes, so a view that also draws in `viewDidChangeEffectiveAppearance` ends on the new colors.
    public static let didChange = Notification.Name("dev.loam.ChromePaletteDidChange")

    private let lock = NSLock()
    private var surfaces: ChromeSurfaces?
    private var opacity: Double = 1

    public init() {}

    public var current: ChromeSurfaces? { lock.withLock { surfaces } }

    /// The Ghostty `background-opacity`, from 0 to 1. Below 1 the window is translucent: the grounds
    /// behind the panes are clear, and the chrome grounds take this alpha (`LoamTheme.ground`).
    public var windowOpacity: Double { lock.withLock { opacity } }
    public var isTranslucent: Bool { windowOpacity < 1 }

    /// How much of what is behind it the sidebar glass hides by itself: about 0.7, measured in the
    /// `frame-shot` driver scenario (ticket 80) in Night.
    public static let sidebarGlassAlpha = 0.7

    /// The alpha of the frame under the sidebar glass, so that frame and glass together let as much
    /// through as a pane does: 1 - (1 - opacity) / (1 - glass). At or below the glass alpha the
    /// frame is clear, and the glass shows alone.
    public static func frameUnderGlassAlpha(windowOpacity: Double, glass: Double = sidebarGlassAlpha) -> Double {
        guard windowOpacity < 1 else { return 1 }
        return max(0, 1 - (1 - windowOpacity) / (1 - glass))
    }

    /// Follows the Ghostty `background-opacity`. Returns true when it changed, so the caller redraws.
    @discardableResult
    public func follow(windowOpacity value: Double) -> Bool {
        let next = value.isFinite ? min(1, max(0, value)) : 1
        let changed = lock.withLock {
            guard next != opacity else { return false }
            opacity = next
            return true
        }
        if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
        return changed
    }

    /// Follows a terminal background. Nil goes back to Loam's tokens. Returns true when the
    /// surfaces changed, so the caller redraws the chrome.
    @discardableResult
    public func follow(terminalBackground background: UInt32?) -> Bool {
        let next = background.map(ChromeSurfaces.derive(background:))
        let changed = lock.withLock {
            guard next != surfaces else { return false }
            surfaces = next
            return true
        }
        if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
        return changed
    }

    /// The value of a surface token for an appearance, or nil for Loam's own token.
    public func value(of token: String, dark: Bool) -> UInt32? {
        guard let surfaces = current, surfaces.isDark == dark else { return nil }
        return surfaces.value(of: token)
    }
}

extension LoamTheme {
    /// A chrome surface (ticket 68): the palette's value when it follows a terminal background
    /// for this appearance, else the Loam token. `scripts/gen-loam-theme.py` uses it for the
    /// names in `ChromeSurfaces.tokenNames`.
    public static func surface(_ name: String, night: UInt32, day: UInt32, palette: ChromePalette = .shared) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return srgb(palette.value(of: name, dark: dark) ?? (dark ? night : day))
        }
    }

    /// The one ground of the chrome around the well (the polish, tickets 87 to 89): the toolbar row,
    /// the margin of the well, the action bar, and the plot panel. `horizon-a` in Night, so the
    /// well (`bedrock`) reads darker than the frame around it, and `horizon-o` in Day, so the well
    /// reads lighter. The glass sidebar keeps `frame` behind it.
    public static func chrome(palette: ChromePalette = .shared) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let token = dark ? "horizon-a" : "horizon-o"
            return srgb(palette.value(of: token, dark: dark) ?? (dark ? 0x211e1a : 0xeeeae2))
        }
    }

    public static let chrome = chrome()

    /// A chrome ground that the window's translucency shows through: `color` with the alpha of
    /// `background-opacity`. With an opaque window it is `color`. Use it for a surface that sits
    /// over the window ground with nothing under it (the toolbar strip, the tab bar, a pane header).
    public static func ground(_ color: NSColor, palette: ChromePalette = .shared) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = color
            appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
            return resolved.withAlphaComponent(CGFloat(palette.windowOpacity))
        }
    }

    /// An NSColor in sRGB as a hex value, for a terminal background from libghostty.
    public static func hex(_ color: NSColor) -> UInt32? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(1, max(0, v)) * 255).rounded()) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }
}

/// Holds a palette-change observer for one view. The view keeps it in a property, and the
/// observer ends when the view goes.
@MainActor
public final class ChromePaletteObserver {
    nonisolated(unsafe) private var token: NSObjectProtocol?

    init(palette: ChromePalette, handler: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(forName: ChromePalette.didChange, object: palette, queue: .main) { _ in
            MainActor.assumeIsolated(handler)
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

extension NSView {
    /// Runs `recolor` each time the palette changes: set the layer colors there. The view also
    /// redraws. A view that draws its own colors needs nothing more. Keep the result in a property.
    @MainActor
    public func observeChromePalette(_ palette: ChromePalette = .shared, recolor: @escaping @MainActor (NSView) -> Void = { _ in }) -> ChromePaletteObserver {
        ChromePaletteObserver(palette: palette) { [weak self] in
            guard let self else { return }
            recolor(self)
            needsDisplay = true
        }
    }
}
