import AppKit
import QuartzCore

/// What an AttentionDot shows (docs/design/components/AttentionDot).
public enum AttentionMark: Sendable, Equatable {
    /// The plot you are in: a `moss` dot.
    case active
    /// Any other plot: a `rule` dot.
    case idle
    /// Needs you: a filled `needs-you` dot.
    case needs
    /// Done, unread: a hollow `done-unread` ring, 1.5 px.
    case unread
}

/// The 8 px dot. Needs you can show the halo: a ring that grows from the dot and fades,
/// `duration-halo` per cycle, three cycles, then the dot stays still. The halo is drawn with
/// Core Animation so a test can read the animation from the layer.
public final class AttentionDotView: NSView {
    public static let size: CGFloat = 8
    static let haloKey = "halo"

    public var mark: AttentionMark = .idle { didSet { if mark != oldValue { refresh() } } }
    /// True when Needs you starts. The halo plays once for each time this turns on.
    public var isArriving = false { didSet { if isArriving != oldValue { refresh() } } }
    /// True while the pane has focus. The halo stops.
    public var paneFocused = false { didSet { if paneFocused != oldValue { refresh() } } }

    private let dot = CALayer()
    private let halo = CAShapeLayer()
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var paletteObserver: ChromePaletteObserver?

    public override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        layer?.addSublayer(halo)
        layer?.addSublayer(dot)
        halo.fillColor = nil
        halo.lineWidth = 1.5
        halo.opacity = 0
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        paletteObserver = observeChromePalette { [weak self] _ in self?.applyColors() }
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    public override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }
    public override var isFlipped: Bool { true }

    /// True while the halo animation is on the layer.
    public var isHaloRunning: Bool { halo.animation(forKey: Self.haloKey) != nil }
    /// The halo animation, for a test.
    public var haloAnimation: CAAnimation? { halo.animation(forKey: Self.haloKey) }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The dot fills the view's smaller side: 8 px in a row, 6 px in the count badge.
    private var diameter: CGFloat {
        let side = min(bounds.width, bounds.height)
        return side > 0 ? side : Self.size
    }

    public override func layout() {
        super.layout()
        let d = diameter
        let rect = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        dot.frame = rect
        dot.cornerRadius = d / 2
        halo.frame = rect
        halo.path = CGPath(ellipseIn: CGRect(origin: .zero, size: rect.size).insetBy(dx: 0.75, dy: 0.75), transform: nil)
    }

    private func refresh() {
        needsLayout = true
        applyColors()
        let cycles = LoamMotion.haloCycles(
            arriving: isArriving && mark == .needs, paneFocused: paneFocused, reduceMotion: LoamMotion.reduceMotion)
        if cycles == 0 {
            halo.removeAnimation(forKey: Self.haloKey)
        } else if !isHaloRunning {
            halo.add(Self.haloAnimation(cycles: cycles), forKey: Self.haloKey)
        }
    }

    static func haloAnimation(cycles: Int) -> CAAnimation {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 3.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = LoamTheme.durationHalo
        group.repeatCount = Float(cycles)
        group.timingFunction = LoamMotion.timingFunction(LoamTheme.easeSettle)
        return group
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch mark {
            case .active: fill(LoamTheme.moss.cgColor)
            case .idle: fill(LoamTheme.rule.cgColor)
            case .needs: fill(LoamTheme.needsYou.cgColor)
            case .unread:
                dot.backgroundColor = nil
                dot.borderColor = LoamTheme.doneUnread.cgColor
                dot.borderWidth = 1.5
            }
            halo.strokeColor = LoamTheme.needsYou.cgColor
        }
        dot.cornerRadius = diameter / 2
    }

    private func fill(_ color: CGColor) {
        dot.backgroundColor = color
        dot.borderWidth = 0
    }
}
