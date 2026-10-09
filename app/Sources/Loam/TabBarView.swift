import AppKit
import LoamKit
import QuartzCore

/// The tab bar at the top of the well (docs/design/components/PaneTab, ticket 88). It is 40 pt
/// tall on `bedrock`, with a hairline under it. Each tab is a pill: 28 pt high, radius 8, the pane
/// symbol, one label (the title of its focused pane, ticket 71), and the strongest attention mark
/// of its panes (an `AttentionDotView`, so Needs you can play the halo). The selected pill has the
/// ink at 9% as a fill, a hairline and `ink` text. Others are `ink-muted`, with the ink at 5% on
/// hover. On hover an `x` takes the place of the symbol (ticket 96) and closes the tab. A `+` button
/// after the last pill starts a new session, as the toolbar `+` does.
///
/// Ticket 98: a press on a pill and a move of 4 pt starts a drag. The pill follows the pointer
/// along the bar, above the others and with a soft shadow, and the others slide aside as the
/// pointer passes their midpoint (`Reorder`). A release settles it into its slot and calls
/// `onMove`. Escape, or a release outside the bar, sends it back. Under Reduce Motion nothing
/// slides: the pill dims, a line marks the drop point, and the release moves it at once.
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
    /// Called with the 0-based tab position when you click the `x` of a tab. The tab does not
    /// become the selected tab first.
    var onClose: ((Int) -> Void)?
    /// Called by the `+` button after the last tab.
    var onNewSession: (() -> Void)?
    /// Called with the 0-based position before and after a drag moves a tab.
    var onMove: ((Int, Int) -> Void)?
    /// A move this far from the press starts a drag. A shorter one is a click.
    static let dragThreshold: CGFloat = 4
    private(set) var items: [TabBarModel.Item] = [] {
        // A drag reads the frames on every frame, so the title widths are measured once per change.
        didSet { widths = items.map(width(of:)) }
    }
    private var widths: [CGFloat] = []
    private var frames: [CGRect] = []
    private var hovered: Int? {
        didSet { if hovered != oldValue { needsLayout = true } }
    }
    /// The press that can become a click or a drag: the tab and the point in the bar.
    private var press: (index: Int, point: CGPoint)?
    private var drag: TabDrag?
    private var displayLink: CADisplayLink?
    private var escapeMonitor: Any?
    /// The one `x`: it sits on the symbol of the hovered tab and hides when no tab is hovered.
    private let close = TabCloseButton(frame: .zero)
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
        close.isHidden = true
        close.onClick = { [weak self] in
            guard let self, let index = self.hovered else { return }
            self.hovered = nil  // The tab list changes, so no tab is under the pointer until it moves.
            self.onClose?(index)
        }
        addSubview(close)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func newSession() { onNewSession?() }

    func update(_ items: [TabBarModel.Item]) {
        let changedSelection = self.items.map(\.isSelected) != items.map(\.isSelected)
        let sameTabs = self.items.map(\.id) == items.map(\.id)
        self.items = items
        if let index = drag?.index {
            // A tab that opens or closes ends the drag where it is. A new title only changes the widths.
            if sameTabs { drag?.reorder = reorder(dragged: index) } else { endDrag() }
        }
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
        let shown = shownFrames()
        let size = AttentionDotView.size
        for (dot, frame) in zip(dots, shown) {
            dot.frame = CGRect(x: frame.maxX - Self.pillPadding - size, y: frame.midY - size / 2, width: size, height: size)
        }
        let side = Self.pillHeight
        let x = (frames.last?.maxX).map { $0 + Self.pillGap } ?? Self.barPadding
        if drag == nil, let index = hovered, items.indices.contains(index) {
            close.frame = Self.iconBox(in: frames[index]).insetBy(dx: -1.5, dy: -1.5)
            close.setAccessibilityIdentifier("tab-close-\(items[index].number)")
            close.isHidden = false
        } else {
            close.isHidden = true
        }
        plus.side = side
        plus.frame = CGRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
    }

    var firstTabFrame: CGRect? { tabFrames().first }

    func tabFrame(at index: Int) -> CGRect? {
        let frames = tabFrames()
        return frames.indices.contains(index) ? frames[index] : nil
    }

    func shownTabFrame(at index: Int) -> CGRect? {
        let frames = shownFrames()
        return frames.indices.contains(index) ? frames[index] : nil
    }

    /// The frames as the tabs draw now: moved by the drag and the slides.
    private func shownFrames() -> [CGRect] {
        let base = tabFrames()
        guard let drag else { return base }
        let now = CACurrentMediaTime()
        return base.enumerated().map { index, frame in frame.offsetBy(dx: drag.offset(of: index, at: now), dy: 0) }
    }

    /// The 13 pt box of the pane symbol. The `x` (16 pt) covers it on hover.
    private static func iconBox(in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + pillPadding, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize)
    }

    private func tabFrames() -> [CGRect] {
        var x = Self.barPadding
        let y = (bounds.height - Self.pillHeight) / 2
        return widths.map { width in
            let rect = CGRect(x: x, y: y, width: width, height: Self.pillHeight)
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
        let shown = shownFrames()
        let dragged = drag?.index
        // The dragged pill draws last, so it sits above the others.
        let order = items.indices.filter { $0 != dragged } + (dragged.map { [$0] } ?? [])
        for index in order {
            let item = items[index]
            let rect = shown[index]
            let context = NSGraphicsContext.current?.cgContext
            context?.saveGState()
            defer { context?.restoreGState() }
            if index == dragged { drawLift(rect) }
            let pill = NSBezierPath(roundedRect: rect, xRadius: Self.pillRadius, yRadius: Self.pillRadius)
            if item.isSelected {
                LoamTheme.inkAlpha(LoamTheme.selectedFillAlpha).setFill()
                pill.fill()
                LoamTheme.hairline.setStroke()
                let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                        xRadius: Self.pillRadius - 0.5, yRadius: Self.pillRadius - 0.5)
                edge.lineWidth = 1
                edge.stroke()
            } else if lit(index) {
                LoamTheme.inkAlpha(LoamTheme.hoverFillAlpha).setFill()
                pill.fill()
            }
            let color = item.isSelected || lit(index) ? LoamTheme.ink : LoamTheme.inkMuted
            let iconColor = item.isSelected || lit(index) ? LoamTheme.inkMuted : LoamTheme.inkFaint
            let iconBox = Self.iconBox(in: rect)
            // On hover the `x` (a subview) takes the place of the symbol.
            if hovered != index || drag != nil, let context, let (mask, size) = iconMask(item.icon) {
                // The symbol as a mask, filled with its color: a drag redraws the bar on every frame.
                let box = CGRect(x: iconBox.midX - size.width / 2, y: iconBox.midY - size.height / 2,
                                 width: size.width, height: size.height)
                context.saveGState()
                context.translateBy(x: 0, y: box.maxY + box.minY)
                context.scaleBy(x: 1, y: -1)
                context.clip(to: box, mask: mask)
                context.setFillColor(iconColor.cgColor)
                context.fill(box)
                context.restoreGState()
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
        drawInsertionLine()
        // The hairline under the bar, the same as the edge of the well.
        LoamTheme.hairline.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill(using: .sourceOver)
    }

    /// The pane symbols as masks at the screen scale, made once each.
    private var iconMasks: [String: (CGImage, CGSize)] = [:]

    private func iconMask(_ icon: LoamIcon) -> (CGImage, CGSize)? {
        let scale = window?.backingScaleFactor ?? 2
        let key = "\(icon)@\(scale)"
        if let cached = iconMasks[key] { return cached }
        guard let image = ChromeIcon.image(icon, pointSize: 11) else { return nil }
        let size = image.size
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        // Draw the symbol, then keep its coverage as a gray mask: white shows, black hides.
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let rgba = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let coverage = Data((0..<width * height).map { rgba[$0 * 4 + 3] })
        guard let provider = CGDataProvider(data: coverage as CFData),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        iconMasks[key] = (mask, size)
        return (mask, size)
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return frames.firstIndex { $0.contains(point) }
    }

    /// A click on a tab's attention dot selects the tab, so the bar takes it. The `x` takes its own click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is AttentionDotView ? self : hit
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A press waits: a release with less than 4 pt of move is a click and selects the tab, a
    /// longer move starts a drag. So a drag never changes the selected tab.
    override func mouseDown(with event: NSEvent) {
        guard drag == nil, let index = index(at: event) else { return }
        press = (index, convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if drag == nil, let press, hypot(point.x - press.point.x, point.y - press.point.y) >= Self.dragThreshold {
            beginDrag(press.index, at: press.point.x)
        }
        guard var drag, drag.phase == .following else { return }
        drag.move(to: point.x, at: CACurrentMediaTime(), reduceMotion: LoamMotion.reduceMotion)
        self.drag = drag
        redraw()
    }

    override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        guard let drag else {
            if let press, items.indices.contains(press.index) { onSelect?(press.index) }
            return
        }
        guard drag.phase == .following else { return }  // Escape already sent it back.
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { drop() } else { cancelDrag() }
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        let now = index(at: event)
        if now != hovered { hovered = now; needsDisplay = true }
    }

    // MARK: Drag (ticket 98)

    /// The hover look: the hovered pill, or the dragged one. No other pill lights up during a drag.
    private func lit(_ index: Int) -> Bool { drag.map { $0.index == index } ?? (hovered == index) }

    private func reorder(dragged: Int) -> Reorder {
        let frames = tabFrames()
        return Reorder(starts: frames.map { Double($0.minX) }, lengths: frames.map { Double($0.width) },
                       spacing: Double(Self.pillGap), dragged: dragged)
    }

    private func beginDrag(_ index: Int, at x: CGFloat) {
        guard items.indices.contains(index) else { return }
        drag = TabDrag(index: index, reorder: reorder(dragged: index), startX: Double(x))
        press = nil  // The press is now a drag, so its release is never a click.
        hovered = nil
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.drag?.phase == .following else { return event }
            self.cancelDrag()
            return nil
        }
        startTicks()
        redraw()
    }

    /// The release: the pill settles into its slot over `duration-base`, then the order changes.
    /// Under Reduce Motion the order changes at once.
    private func drop() {
        guard var drag else { return }
        let slot = drag.slot
        if slot != drag.index, LoamMotion.reduceMotion { return commit(from: drag.index, to: slot) }
        drag.settle(at: CACurrentMediaTime(), reduceMotion: LoamMotion.reduceMotion)
        self.drag = drag
        redraw()
    }

    /// Escape or a release outside the bar: every pill goes back over `duration-slow`.
    private func cancelDrag() {
        guard var drag else { return }
        drag.cancel(at: CACurrentMediaTime(), reduceMotion: LoamMotion.reduceMotion)
        self.drag = drag
        redraw()
    }

    /// The new order shows at once with no offsets, then the workspace takes it.
    private func commit(from: Int, to: Int) {
        endDrag()
        guard items.indices.contains(from), items.indices.contains(to) else { return }
        var next = items
        next.insert(next.remove(at: from), at: to)
        items = next
        // Each dot goes with its tab, so a halo that plays keeps playing.
        dots.insert(dots.remove(at: from), at: to)
        needsLayout = true
        needsDisplay = true
        onMove?(from, to)
    }

    private func endDrag() {
        drag = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        displayLink?.invalidate()
        displayLink = nil
        redraw()
    }

    private func startTicks() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        guard let drag else { return endDrag() }
        let now = CACurrentMediaTime()
        switch drag.phase {
        case .following: break
        case .settling where drag.isDone(at: now):
            return drag.slot == drag.index ? endDrag() : commit(from: drag.index, to: drag.slot)
        case .returning where drag.isDone(at: now):
            return endDrag()
        default: break
        }
        // While you hold the pill still, nothing slides, so nothing draws. A pointer move redraws itself.
        if drag.phase != .following || !drag.isDone(at: now - 1 / 60) { redraw() }
    }

    /// A bar that leaves the window mid-drag ends the drag, so the display link stops.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, drag != nil { endDrag() }
    }

    private func redraw() {
        needsLayout = true
        needsDisplay = true
    }

    /// The soft shadow and an opaque ground under the dragged pill, so the pills it passes do not show through.
    private func drawLift(_ rect: CGRect) {
        let pill = NSBezierPath(roundedRect: rect, xRadius: Self.pillRadius, yRadius: Self.pillRadius)
        if LoamMotion.reduceMotion {
            // It stays in place and dims. The line shows where it goes.
            NSGraphicsContext.current?.cgContext.setAlpha(0.5)
            return
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        LoamTheme.ground(LoamTheme.bedrock).setFill()
        pill.fill()
        NSGraphicsContext.restoreGraphicsState()
        LoamTheme.hairline.setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: Self.pillRadius - 0.5, yRadius: Self.pillRadius - 0.5)
        edge.lineWidth = 1
        edge.stroke()
    }

    /// Under Reduce Motion, a 2 pt `moss` line in the gap where the dragged tab will land.
    private func drawInsertionLine() {
        guard let drag, drag.phase == .following, LoamMotion.reduceMotion,
              let x = drag.reorder.insertionPoint(slot: drag.slot) else { return }
        let frames = tabFrames()
        guard let first = frames.first else { return }
        LoamTheme.moss.setFill()
        NSBezierPath(roundedRect: CGRect(x: CGFloat(x) - 1, y: first.minY, width: 2, height: first.height),
                     xRadius: 1, yRadius: 1).fill()
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

/// One tab drag (ticket 98): the pointer, the slot, and the slides of every pill. The dragged
/// pill follows the pointer until the release. Then it slides too: into its slot, or back.
private struct TabDrag {
    enum Phase { case following, settling, returning }
    let index: Int
    var reorder: Reorder
    let startX: Double
    var phase = Phase.following
    var slot: Int
    /// Where the dragged pill sits while it follows the pointer.
    var follow = 0.0
    /// The slide of each pill, by position. The dragged pill gets one on the release.
    var slides: [Int: Slide] = [:]

    init(index: Int, reorder: Reorder, startX: Double) {
        self.index = index
        self.reorder = reorder
        self.startX = startX
        slot = index
    }

    func offset(of tab: Int, at time: TimeInterval) -> CGFloat {
        if tab == index, phase == .following { return CGFloat(follow) }
        return CGFloat(slides[tab]?.value(at: time) ?? 0)
    }

    /// The pointer moved. The pill stays on the bar, and the others slide over `duration-base`
    /// when the slot changes. Under Reduce Motion nothing moves: only the slot changes.
    mutating func move(to x: Double, at time: TimeInterval, reduceMotion: Bool) {
        let starts = reorder.starts, lengths = reorder.lengths
        let low = starts[0] - starts[index]
        let high = (starts[starts.count - 1] + lengths[lengths.count - 1]) - (starts[index] + lengths[index])
        follow = reduceMotion ? 0 : min(max(x - startX, low), high)
        let next = reorder.slot(pointer: x)
        guard next != slot else { return }
        slot = next
        guard !reduceMotion else { return }
        for tab in reorder.starts.indices where tab != index {
            slideTo(tab, reorder.offset(of: tab, slot: slot), at: time, duration: LoamTheme.durationBase)
        }
    }

    /// The release: the dragged pill slides from where it is into its slot.
    mutating func settle(at time: TimeInterval, reduceMotion: Bool) {
        slides[index] = .at(follow)
        phase = .settling
        slideTo(index, reorder.settleOffset(slot: slot), at: time,
                duration: reduceMotion ? 0 : LoamTheme.durationBase)
    }

    /// Escape or a release outside: every pill slides back to where it started.
    mutating func cancel(at time: TimeInterval, reduceMotion: Bool) {
        slides[index] = .at(follow)
        phase = .returning
        slot = index
        for tab in reorder.starts.indices {
            slideTo(tab, 0, at: time, duration: reduceMotion ? 0 : LoamTheme.durationSlow)
        }
    }

    private mutating func slideTo(_ tab: Int, _ target: Double, at time: TimeInterval, duration: TimeInterval) {
        let now = slides[tab]?.value(at: time) ?? 0
        slides[tab] = Slide(from: now, to: target, start: time, duration: now == target ? 0 : duration)
    }

    func isDone(at time: TimeInterval) -> Bool { slides.values.allSatisfy { $0.isDone(at: time) } }
}

/// The `x` on a hovered tab (ticket 96): a 16 pt square, the ink at 5% and radius 4 on hover,
/// `xmark` at 9 pt in `ink-muted`, and `ink` on its own hover. It closes on `mouseDown`.
final class TabCloseButton: NSView {
    var onClick: (() -> Void)?
    private var overButton = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Close tab")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { overButton = true }
    override func mouseExited(with event: NSEvent) { overButton = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }

    override var isHidden: Bool {
        didSet { if isHidden { overButton = false } }
    }

    override func draw(_ dirtyRect: NSRect) {
        if overButton {
            LoamTheme.inkAlpha(LoamTheme.hoverFillAlpha).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        guard let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        ChromeIcon.draw(image, in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                          width: size.width, height: size.height),
                        color: overButton ? LoamTheme.ink : LoamTheme.inkMuted)
    }
}
