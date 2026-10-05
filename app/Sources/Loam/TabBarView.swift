import AppKit
import LoamKit
import QuartzCore

/// The tab bar at the top of the well (docs/design/components/PaneTab, ticket 88). It is 40 pt
/// tall on `bedrock`, with a hairline under it. Each tab is a pill: 28 pt high, radius 8, the pane
/// symbol, one label (the title of its focused pane, ticket 71), and the strongest attention mark
/// of its panes (an `AttentionDotView`, so Needs you can play the halo). The selected pill has the
/// ink at 9% as a fill, a hairline and `ink` text. Others are `ink-muted`, with the ink at 5% on
/// hover. A `+` button after the last pill starts a new session, as the toolbar `+` does.
final class TabBarView: NSView, FirstTabFraming {
    static let height: CGFloat = 40
    static let pillHeight: CGFloat = 28
    static let pillRadius: CGFloat = 8
    static let pillPadding: CGFloat = 11
    static let pillGap: CGFloat = 4
    static let barPadding: CGFloat = 8
    static let iconSize: CGFloat = 13
    static let iconGap: CGFloat = 7

    /// Called with the 0-based tab position when you click a tab.
    var onSelect: ((Int) -> Void)?
    /// Called by the `+` button after the last tab.
    var onNewSession: (() -> Void)?
    private(set) var items: [TabBarModel.Item] = []
    private var frames: [CGRect] = []
    private var hovered: Int?
    /// One dot per tab, hidden when the tab has no mark.
    private var dots: [AttentionDotView] = []
    private let plus = ChromeIconButton(symbol: "plus", label: "New session", identifier: "tab-new-session")

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityIdentifier("tab-bar")
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
        plus.target = self
        plus.action = #selector(newSession)
        addSubview(plus)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func newSession() { onNewSession?() }

    func update(_ items: [TabBarModel.Item]) {
        let changedSelection = self.items.map(\.isSelected) != items.map(\.isSelected)
        self.items = items
        if changedSelection, !self.items.isEmpty { fade() }
        while dots.count < items.count {
            let dot = AttentionDotView(frame: .zero)
            addSubview(dot)
            dots.append(dot)
        }
        while dots.count > items.count { dots.removeLast().removeFromSuperview() }
        for (dot, item) in zip(dots, items) {
            dot.isHidden = item.attention == .none
            dot.mark = item.attention == .doneUnread ? .unread : .needs
            dot.paneFocused = item.paneFocused
            dot.isArriving = item.isArriving
            dot.setAccessibilityIdentifier("tab-mark-\(item.number)")
            dot.setAccessibilityElement(item.attention != .none)
            dot.setAccessibilityValue(item.attention.rawValue)
        }
        needsLayout = true
        needsDisplay = true
        superview?.needsLayout = true
    }

    override func layout() {
        super.layout()
        frames = tabFrames()
        let size = AttentionDotView.size
        for (dot, frame) in zip(dots, frames) {
            dot.frame = CGRect(x: frame.maxX - Self.pillPadding - size, y: frame.midY - size / 2, width: size, height: size)
        }
        let side = Self.pillHeight
        let x = (frames.last?.maxX).map { $0 + Self.pillGap } ?? Self.barPadding
        plus.side = side
        plus.frame = CGRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
    }

    var firstTabFrame: CGRect? { tabFrames().first }

    private func tabFrames() -> [CGRect] {
        var x = Self.barPadding
        let y = (bounds.height - Self.pillHeight) / 2
        return items.map { item in
            let rect = CGRect(x: x, y: y, width: width(of: item), height: Self.pillHeight)
            x = rect.maxX + Self.pillGap
            return rect
        }
    }

    /// The trailing slot: a gap and the 8 px dot, only when the tab has a mark.
    private func markWidth(of item: TabBarModel.Item) -> CGFloat {
        item.attention == .none ? 0 : Self.iconGap + AttentionDotView.size
    }

    /// A tab switch changes color over `duration-base` with `ease-settle`. It moves nothing, so it
    /// also runs under Reduce Motion.
    private func fade() {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = LoamTheme.durationBase
        transition.timingFunction = LoamMotion.timingFunction(LoamTheme.easeSettle)
        layer?.add(transition, forKey: "tab-switch")
    }

    private let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    /// The padding, the symbol, the title (at most 220 pt), and the mark.
    private func width(of item: TabBarModel.Item) -> CGFloat {
        let title = (item.title as NSString).size(withAttributes: [.font: titleFont]).width
        return Self.pillPadding * 2 + Self.iconSize + Self.iconGap + min(220, ceil(title)) + markWidth(of: item)
    }

    override func draw(_ dirtyRect: NSRect) {
        // In a translucent window the bar takes the window's alpha (`LoamTheme.ground`).
        LoamTheme.ground(LoamTheme.bedrock).setFill()
        bounds.fill(using: .copy)
        frames = tabFrames()
        for (index, item) in items.enumerated() {
            let rect = frames[index]
            let pill = NSBezierPath(roundedRect: rect, xRadius: Self.pillRadius, yRadius: Self.pillRadius)
            if item.isSelected {
                LoamTheme.inkAlpha(LoamTheme.selectedFillAlpha).setFill()
                pill.fill()
                LoamTheme.hairline.setStroke()
                let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                        xRadius: Self.pillRadius - 0.5, yRadius: Self.pillRadius - 0.5)
                edge.lineWidth = 1
                edge.stroke()
            } else if hovered == index {
                LoamTheme.inkAlpha(LoamTheme.hoverFillAlpha).setFill()
                pill.fill()
            }
            let color = item.isSelected || hovered == index ? LoamTheme.ink : LoamTheme.inkMuted
            let iconColor = item.isSelected || hovered == index ? LoamTheme.inkMuted : LoamTheme.inkFaint
            let iconBox = CGRect(x: rect.minX + Self.pillPadding, y: rect.midY - Self.iconSize / 2,
                                 width: Self.iconSize, height: Self.iconSize)
            if let image = ChromeIcon.image(item.icon, pointSize: 11) {
                let size = image.size
                ChromeIcon.draw(image, in: CGRect(x: iconBox.midX - size.width / 2, y: iconBox.midY - size.height / 2,
                                                  width: size.width, height: size.height), color: iconColor)
            }
            let titleX = iconBox.maxX + Self.iconGap
            let titleRect = CGRect(x: titleX, y: rect.midY - 8,
                                   width: max(0, rect.maxX - Self.pillPadding - markWidth(of: item) - titleX), height: 16)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            (item.title as NSString).draw(in: titleRect, withAttributes: [
                .font: titleFont, .foregroundColor: color, .paragraphStyle: style,
            ])
        }
        // The hairline under the bar, the same as the edge of the well.
        LoamTheme.hairline.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill(using: .sourceOver)
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return frames.firstIndex { $0.contains(point) }
    }

    /// A click on a tab's attention dot selects the tab, so the bar takes it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is AttentionDotView ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        if let index = index(at: event) { onSelect?(index) }
    }

    override func mouseMoved(with event: NSEvent) {
        let now = index(at: event)
        if now != hovered { hovered = now; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
