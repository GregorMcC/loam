import AppKit
import LoamKit

/// The middle column (ticket 88): the terminal well, inset in the window frame. The column runs
/// under the toolbar and paints the frame around the well, so the toolbar's glass items stand on
/// the frame. A margin of frame shows above the well, and on each side where no sidebar or panel
/// touches it (`WellLayout`).
///
/// In a translucent window the frame is `ground(frame)` and fills only the margin: the column
/// leaves the well's rounded rect clear, so nothing sits behind a pane (tickets 80, 82, 85).
///
/// Ticket 69 tried `topAlignedAccessoryViewControllers` for the tab bar. The bar then left the
/// accessibility tree (VoiceOver and the driver lost it), so the bar stays in the column. The top
/// edge of the well is a constraint on the safe area guide, so full screen, a toolbar show or hide,
/// and a titlebar style change lay it out again with no code of ours.
final class PaneColumnView: NSView {
    private let tabBar: TabBarView
    private let barHeight: NSLayoutConstraint
    let well = WellView()
    private var top: NSLayoutConstraint!
    private var left: NSLayoutConstraint!
    private var right: NSLayoutConstraint!
    private var bottom: NSLayoutConstraint!
    private var paletteObserver: ChromePaletteObserver?
    private var sidebarShown = true
    private var panelShown = false

    /// The room under the well: the frame margin, or a row that stands under the well.
    var bottomInset: CGFloat = WellLayout.bottomMargin {
        didSet { applyInsets() }
    }

    init(tabBar: TabBarView, paneArea: PaneAreaView) {
        self.tabBar = tabBar
        barHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        well.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        paneArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(well)
        well.addSubview(paneArea)
        well.addSubview(tabBar)
        top = well.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor)
        left = well.leadingAnchor.constraint(equalTo: leadingAnchor)
        right = trailingAnchor.constraint(equalTo: well.trailingAnchor)
        bottom = bottomAnchor.constraint(equalTo: well.bottomAnchor)
        NSLayoutConstraint.activate([
            top, left, right, bottom,
            tabBar.topAnchor.constraint(equalTo: well.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            barHeight,
            paneArea.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            paneArea.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            paneArea.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            paneArea.bottomAnchor.constraint(equalTo: well.bottomAnchor),
        ])
        applyInsets()
        paletteObserver = observeChromePalette()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The bar hides when the plot has no tab.
    func setTabBarShown(_ shown: Bool) {
        tabBar.isHidden = !shown
        barHeight.constant = shown ? TabBarView.height : 0
    }

    /// Which regions touch the well: the sidebar on the left, the plot panel on the right.
    func setNeighbours(sidebar: Bool, panel: Bool) {
        guard sidebar != sidebarShown || panel != panelShown else { return }
        sidebarShown = sidebar
        panelShown = panel
        applyInsets()
    }

    private func applyInsets() {
        let insets = WellLayout.insets(sidebarShown: sidebarShown, panelShown: panelShown, bottom: bottomInset)
        top.constant = insets.top
        left.constant = insets.left
        right.constant = insets.right
        bottom.constant = insets.bottom
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        needsDisplay = true  // The margin follows the well.
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The frame around the well. A solid window fills the whole column, and the opaque well covers
    /// its part. A translucent window fills only the margin, so the frame does not stack its alpha
    /// under the panes.
    override func draw(_ dirtyRect: NSRect) {
        LoamTheme.ground(LoamTheme.chrome).setFill()
        guard ChromePalette.shared.isTranslucent else { return bounds.fill() }
        let card = well.frame
        let radius = WellLayout.cornerRadius
        NSGraphicsContext.current?.compositingOperation = .copy
        Self.fill(around: NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius), in: bounds)
        // On a curve the frame and the clipped panes each cover only part of an edge pixel, so
        // together they let the window through: a light arc. In the corner squares only, the frame
        // also runs `cornerOverlap` under the arc, where the hairline covers it.
        let overlap = Self.cornerOverlap
        let inner = NSBezierPath(roundedRect: card.insetBy(dx: overlap, dy: overlap),
                                 xRadius: radius - overlap, yRadius: radius - overlap)
        for x in [card.minX, card.maxX - radius] {
            for y in [card.minY, card.maxY - radius] {
                let square = CGRect(x: x, y: y, width: radius, height: radius)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: square).addClip()
                Self.fill(around: inner, in: square)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    /// How far the frame runs under the arc of a corner, in points.
    static let cornerOverlap: CGFloat = 0.25

    private static func fill(around hole: NSBezierPath, in rect: CGRect) {
        let path = NSBezierPath(rect: rect)
        path.append(hole)
        path.windingRule = .evenOdd
        path.fill()
    }
}

/// The card that holds the tab bar and the panes: a 12 pt corner radius that clips the panes, and a
/// hairline edge over them. In a solid window it is `bedrock`. In a translucent window it is clear,
/// and each region in it paints its own ground at the window alpha.
final class WellView: NSView {
    private var paletteObserver: ChromePaletteObserver?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = WellLayout.cornerRadius
        layer?.cornerCurve = .circular  // The same arc as the margin path of the column.
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        paletteObserver = observeChromePalette { [weak self] _ in self?.applyColors() }
        setAccessibilityIdentifier("well")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = ChromePalette.shared.isTranslucent ? NSColor.clear.cgColor : LoamTheme.bedrock.cgColor
            layer?.borderColor = LoamTheme.hairline.cgColor
        }
    }
}

/// A small icon button on the chrome: an SF Symbol in `ink-faint`, with the ink at 5% as a fill
/// and `ink` on hover (polish README, `.ibtn`).
final class ChromeIconButton: NSButton {
    private var hovered = false { didSet { needsDisplay = true } }
    private let symbol: String
    var side: CGFloat = 28

    init(symbol: String, label: String, identifier: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        toolTip = label
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            LoamTheme.inkAlpha(LoamTheme.hoverFillAlpha).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let size = image.size
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        ChromeIcon.draw(image, in: rect, color: hovered ? LoamTheme.ink : LoamTheme.inkFaint)
    }
}

/// Draws a template image (an SF Symbol or a brand mark) in one color.
enum ChromeIcon {
    static func draw(_ image: NSImage, in rect: CGRect, color: NSColor) {
        let tinted = NSImage(size: rect.size, flipped: false) { bounds in
            image.draw(in: bounds)
            color.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The image of an icon at a point size: an SF Symbol, or a brand mark scaled to that size.
    @MainActor static func image(_ icon: LoamIcon, pointSize: CGFloat) -> NSImage? {
        switch icon {
        case .symbol(let name):
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium))
        case .brand(let mark):
            {
                let image = mark.image.copy() as! NSImage
                image.size = NSSize(width: pointSize + 1, height: pointSize + 1)
                return image
            }()
        }
    }
}
