import AppKit
import QuartzCore

/// Fonts for the type styles of `LoamTheme`. Hand-written. The values come from the generated file.
extension LoamTheme {
    /// The AppKit font of a type style. UI text uses the system face. The terminal and display
    /// faces fall back to the system monospace face when the named font is not installed.
    public static func font(_ style: TypeStyle) -> NSFont {
        let weight = fontWeight(style.weight)
        switch style.family {
        case "mono":
            return NSFont(name: "JetBrains Mono", size: style.size)
                ?? .monospacedSystemFont(ofSize: style.size, weight: weight)
        case "display":
            return NSFont(name: "Martian Mono", size: style.size)
                ?? .monospacedSystemFont(ofSize: style.size, weight: weight)
        default:
            return .systemFont(ofSize: style.size, weight: weight)
        }
    }

    /// Maps a CSS weight to `NSFont.Weight`. 650 sits between semibold and bold.
    public static func fontWeight(_ css: Int) -> NSFont.Weight {
        switch css {
        case ..<450: .regular
        case ..<550: .medium
        case ..<620: .semibold
        default: NSFont.Weight(rawValue: 0.34)
        }
    }

    /// Extra points between lines so the line box is `lineHeight` tall.
    public static func lineSpacing(_ style: TypeStyle) -> CGFloat {
        let font = font(style)
        return max(0, style.lineHeight - (font.ascender - font.descender + font.leading))
    }
}

/// Motion rules (docs/design/README.md, Motion).
public enum LoamMotion {
    /// The Needs you halo runs this many cycles on arrival.
    public static let haloCycles = 3

    /// Set by a test or the driver. Nil follows the system Reduce Motion setting.
    nonisolated(unsafe) public static var reduceMotionOverride: Bool?

    public static var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static func timingFunction(_ easing: LoamTheme.Easing) -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: easing.x1, easing.y1, easing.x2, easing.y2)
    }

    /// How many halo cycles to run. The halo is the only loop. It runs only on arrival, never
    /// while the pane has focus, and never under Reduce Motion.
    public static func haloCycles(arriving: Bool, paneFocused: Bool, reduceMotion: Bool) -> Int {
        arriving && !paneFocused && !reduceMotion ? haloCycles : 0
    }
}
