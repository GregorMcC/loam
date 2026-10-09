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

extension LoamTheme.Easing {
    /// The eased progress at `time` (0 to 1) on this cubic Bezier, for motion that a display link
    /// draws frame by frame, such as the tab slide (ticket 98). It solves x(s) = time for s, then
    /// returns y(s).
    public func progress(at time: Double) -> Double {
        let t = min(max(time, 0), 1)
        let (x1, y1, x2, y2) = (Double(x1), Double(y1), Double(x2), Double(y2))
        func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let inverse = 1 - s
            return 3 * inverse * inverse * s * a + 3 * inverse * s * s * b + s * s * s
        }
        func slope(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let inverse = 1 - s
            return 3 * inverse * inverse * a + 6 * inverse * s * (b - a) + 3 * s * s * (1 - b)
        }
        var s = t
        for _ in 0..<8 {
            let error = bezier(s, x1, x2) - t
            if abs(error) < 1e-6 { return bezier(s, y1, y2) }
            let d = slope(s, x1, x2)
            if abs(d) < 1e-6 { break }
            s -= error / d
        }
        // Newton did not settle: bisect.
        var low = 0.0, high = 1.0
        s = t
        for _ in 0..<40 {
            let x = bezier(s, x1, x2)
            if abs(x - t) < 1e-6 { break }
            if x < t { low = s } else { high = s }
            s = (low + high) / 2
        }
        return bezier(s, y1, y2)
    }
}

/// One value that slides from `from` to `to` over `duration` with an easing (ticket 98). A view
/// that draws itself reads `value(at:)` on each display link tick.
public struct Slide: Equatable, Sendable {
    public var from: Double
    public var to: Double
    public var start: TimeInterval
    public var duration: TimeInterval
    public var easing: LoamTheme.Easing

    public init(from: Double, to: Double, start: TimeInterval, duration: TimeInterval,
                easing: LoamTheme.Easing = LoamTheme.easeSettle) {
        self.from = from
        self.to = to
        self.start = start
        self.duration = duration
        self.easing = easing
    }

    /// A slide that is already at `value`.
    public static func at(_ value: Double) -> Slide {
        Slide(from: value, to: value, start: 0, duration: 0)
    }

    public func value(at time: TimeInterval) -> Double {
        guard duration > 0, time < start + duration else { return to }
        return from + (to - from) * easing.progress(at: (time - start) / duration)
    }

    public func isDone(at time: TimeInterval) -> Bool { duration <= 0 || time >= start + duration }
}
