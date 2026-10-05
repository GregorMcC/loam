import AppKit
import LoamKit
import QuartzCore

/// One pane: a thin header over the content view from the factory. The header takes the well's
/// look (ticket 88): `bedrock`, with a hairline under it, as under the tab bar. The focused pane
/// has `ink` text, the others `ink-muted`. Only a pane in a split tab has the header (ticket 71).
final class PaneContainerView: NSView {
    private var paletteObserver: ChromePaletteObserver?
    static let headerHeight: CGFloat = 22

    let paneID: PaneID
    let content: NSView
    var onActivate: ((PaneID) -> Void)?

    private let header = NSView()
    private let headerLine = CALayer()
    private var isFocused = false
    /// The pane ring (spec 8.4): amber for Needs you, blue for Done, unread. It sits over the
    /// terminal and takes no clicks.
    private let ring = PaneRingView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    /// The worktree branch, after the title (spec 8.1). Hidden outside a worktree.
    private let branchLabel = NSTextField(labelWithString: "")

    init(paneID: PaneID, content: NSView) {
        self.paneID = paneID
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        paletteObserver = observeChromePalette { [weak self] _ in self?.applyColors() }
        header.wantsLayer = true
        headerLine.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        header.layer?.addSublayer(headerLine)
        for label in [titleLabel, branchLabel, stateLabel] {
            label.font = LoamTheme.font(LoamTheme.captionStyle)
            label.lineBreakMode = .byTruncatingTail
            header.addSubview(label)
        }
        branchLabel.isHidden = true
        branchLabel.setAccessibilityIdentifier("pane-branch-\(paneID.uuidString)")
        addSubview(header)
        addSubview(content)
        addSubview(ring)
        ring.setAccessibilityIdentifier("pane-ring-\(paneID.uuidString)")
        stateLabel.setAccessibilityIdentifier("pane-state-\(paneID.uuidString)")
        setAccessibilityIdentifier("pane-\(paneID.uuidString)")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The "Session ended" bar of a seeded pane whose process exited. Nil until it first shows.
    private(set) var endedBar: SessionEndedBar?
    var onResume: ((PaneID) -> Void)?
    var onNewSession: ((PaneID) -> Void)?
    var onClose: ((PaneID) -> Void)?

    /// The view that takes the keys: the ended bar while it shows, else the terminal.
    var focusTarget: NSView { endedBar.map { $0.isHidden ? content : $0 } ?? content }

    /// Shows or hides the "Session ended" bar.
    func showEnded(_ show: Bool, canResume: Bool, note: String? = nil) {
        if show, endedBar == nil {
            let bar = SessionEndedBar(paneID: paneID)
            bar.onResume = { [weak self] in self.map { $0.onResume?($0.paneID) } }
            bar.onNewSession = { [weak self] in self.map { $0.onNewSession?($0.paneID) } }
            bar.onClose = { [weak self] in self.map { $0.onClose?($0.paneID) } }
            addSubview(bar, positioned: .below, relativeTo: ring)
            endedBar = bar
            needsLayout = true
        }
        endedBar?.canResume = canResume
        endedBar?.note = note
        if endedBar?.isHidden == show { endedBar?.isHidden = !show; needsLayout = true }
    }

    /// `attention` sets the ring and the state words: "Needs you" in amber, "Done, unread" in blue.
    /// `showsHeader` false hides the header (`Workspace.showsHeader`, ticket 71): in a tab of one pane
    /// the tab label, the tab dot and the ring say the same, so the terminal takes the full height.
    func update(title: String, state: PaneState, focused: Bool, branch: String? = nil, attention: PaneAttention = .none,
                showsHeader: Bool = true) {
        header.isHidden = !showsHeader
        titleLabel.stringValue = title
        let label = attention == .doneUnread ? "Done, unread" : state.label
        stateLabel.stringValue = label
        titleLabel.textColor = focused ? LoamTheme.ink : LoamTheme.inkMuted
        stateLabel.textColor = switch attention {
        case .needsYou: LoamTheme.needsYou
        case .doneUnread: LoamTheme.doneUnread
        case .none: LoamTheme.inkFaint
        }
        branchLabel.stringValue = branch ?? ""
        branchLabel.isHidden = branch == nil
        branchLabel.textColor = LoamTheme.inkMuted
        isFocused = focused
        ring.attention = attention
        applyColors()
        needsLayout = true
        setAccessibilityLabel(["\(title)", branch, label].compactMap { $0 }.joined(separator: ", "))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// A layer takes a fixed color, so each appearance change resolves the tokens again.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            header.layer?.backgroundColor = LoamTheme.ground(LoamTheme.bedrock).cgColor
            headerLine.backgroundColor = LoamTheme.hairline.cgColor
        }
    }

    override func layout() {
        super.layout()
        let h = header.isHidden ? 0 : Self.headerHeight
        header.frame = CGRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        headerLine.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        let bar = endedBar.map { $0.isHidden ? 0 : SessionEndedBar.height } ?? 0
        endedBar?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bar)
        content.frame = CGRect(x: 0, y: bar, width: bounds.width, height: max(0, bounds.height - h - bar))
        ring.frame = bounds
        let stateWidth: CGFloat = 90  // Room for "Done, unread".
        let room = max(0, bounds.width - stateWidth - 16)
        if branchLabel.isHidden {
            titleLabel.frame = CGRect(x: 8, y: 3, width: room, height: 16)
        } else {
            // The title keeps its width and the branch takes the rest, so a long branch gets cut first.
            let titleWidth = min(ceil(titleLabel.attributedStringValue.size().width) + 4, room)
            titleLabel.frame = CGRect(x: 8, y: 3, width: titleWidth, height: 16)
            let gap: CGFloat = 8
            branchLabel.frame = CGRect(x: 8 + titleWidth + gap, y: 3, width: max(0, room - titleWidth - gap), height: 16)
        }
        stateLabel.frame = CGRect(x: bounds.width - stateWidth - 8, y: 3, width: stateWidth, height: 16)
        stateLabel.alignment = .right
    }

    /// A click anywhere in the pane focuses it, also when a terminal surface takes the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .leftMouseDown { onActivate?(paneID) }
        return hit
    }
}

/// The pane ring (spec 8.4, docs/design): a 2 px line inside the pane edge, `needs-you` amber for
/// Needs you and `done-unread` blue for Done, unread. No ring for any other state. A color change
/// fades over `duration-fast`, also under Reduce Motion, because it moves nothing.
final class PaneRingView: NSView {
    private var paletteObserver: ChromePaletteObserver?
    static let width: CGFloat = 2

    var attention: PaneAttention = .none {
        didSet {
            guard attention != oldValue else { return }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = LoamTheme.durationFast
            layer?.add(fade, forKey: "ring")
            applyColors()
            setAccessibilityValue(attention.rawValue)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        paletteObserver = observeChromePalette { [weak self] _ in self?.applyColors() }
        layer?.borderWidth = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityValue(attention.rawValue)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The ring takes no clicks: they go to the terminal under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch attention {
            case .needsYou:
                layer?.borderColor = LoamTheme.needsYou.cgColor
                layer?.borderWidth = Self.width
            case .doneUnread:
                layer?.borderColor = LoamTheme.doneUnread.cgColor
                layer?.borderWidth = Self.width
            case .none:
                layer?.borderWidth = 0
            }
        }
    }
}

/// The middle of the window. It holds every pane view of every plot and shows only the visible tab's tree.
/// Other plots keep their views, hidden, so their surfaces stay alive.
final class PaneAreaView: NSView {
    private var paletteObserver: ChromePaletteObserver?
    static let dividerWidth: CGFloat = 1
    /// The smallest a pane may get in a divider drag, in points.
    static let minPaneSize: CGFloat = 80
    /// How far from the 1 point divider a click still grabs it.
    static let grabSlop: CGFloat = 3

    /// Called while a divider moves: the split path and the new ratio.
    var onDividerDrag: (([Int], Double) -> Void)?
    private var dragging: SplitTree.Divider?

    private var containers: [PaneID: PaneContainerView] = [:]
    private var tree: SplitTree?
    private let emptyLabel = NSTextField(labelWithString: "Press \u{2318}T to start a session.\nPress \u{2318}\u{2325}T to open a shell.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // A change of translucency adds or removes the divider layers.
        paletteObserver = observeChromePalette { [weak self] _ in self?.needsLayout = true; self?.applyColors() }
        emptyLabel.font = LoamTheme.font(LoamTheme.emptyTitleStyle)
        emptyLabel.textColor = LoamTheme.inkMuted
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.setAccessibilityIdentifier("empty-hint")
        addSubview(emptyLabel)
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

    /// The area stands on the divider color, which shows through the 1 px divider gap: the hairline
    /// of the well (the ink at 8%) mixed into `bedrock`, so a split reads as soft as the well edge
    /// (ticket 88). In a translucent window the area is clear, so the desktop shows through the
    /// panes, and each divider is a layer at the window alpha. With no tab the area takes `bedrock`.
    private func applyColors() {
        let translucent = ChromePalette.shared.isTranslucent
        let divider = LoamTheme.inkOver(LoamTheme.bedrock, alpha: LoamTheme.hairlineAlpha)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tree == nil ? LoamTheme.ground(LoamTheme.bedrock).cgColor
                : translucent ? NSColor.clear.cgColor : divider.cgColor
            for line in dividerLayers { line.backgroundColor = LoamTheme.ground(divider).cgColor }
        }
    }

    /// One `rule` layer per divider, in a translucent window.
    private var dividerLayers: [CALayer] = []

    private func layoutDividers() {
        let frames = ChromePalette.shared.isTranslucent ? dividers.map(\.frame) : []
        let count = dividerLayers.count
        while dividerLayers.count > frames.count { dividerLayers.removeLast().removeFromSuperlayer() }
        while dividerLayers.count < frames.count {
            let line = CALayer()
            line.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(line)
            dividerLayers.append(line)
        }
        for (line, frame) in zip(dividerLayers, frames) { line.frame = frame }
        // A drag lays out on each frame. Colors change only with the layers, the tree, or the palette.
        if dividerLayers.count != count { applyColors() }
    }

    func container(for pane: PaneID) -> PaneContainerView? { containers[pane] }
    var paneIDs: Set<PaneID> { Set(containers.keys) }

    func add(_ container: PaneContainerView) {
        containers[container.paneID] = container
        container.isHidden = true
        addSubview(container)
    }

    /// Hides the container and returns it. The caller removes it after the surface closes.
    func detach(_ pane: PaneID) -> PaneContainerView? {
        guard let container = containers.removeValue(forKey: pane) else { return nil }
        container.isHidden = true
        return container
    }

    func show(_ tree: SplitTree?) {
        let hadTree = self.tree != nil
        self.tree = tree
        needsLayout = true
        if hadTree != (tree != nil) { applyColors() }  // The ground with no tab differs.
    }

    private var dividers: [SplitTree.Divider] {
        tree?.dividers(in: bounds, gap: Self.dividerWidth) ?? []
    }

    private func grabRect(_ d: SplitTree.Divider) -> CGRect {
        d.frame.insetBy(dx: d.axis == .sideBySide ? -Self.grabSlop : 0, dy: d.axis == .stacked ? -Self.grabSlop : 0)
    }

    private func divider(at point: CGPoint) -> SplitTree.Divider? {
        dividers.last { grabRect($0).contains(point) }  // The innermost split wins.
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !isHidden, divider(at: convert(point, from: superview)) != nil { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        for d in dividers {
            addCursorRect(grabRect(d), cursor: d.axis == .sideBySide ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = divider(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = dragging else { return }
        let ratio = d.ratio(at: convert(event.locationInWindow, from: nil), minPaneSize: Self.minPaneSize)
        tree = tree?.settingRatio(ratio, at: d.path)  // Move at once. The model catches up on the next render.
        needsLayout = true
        window?.invalidateCursorRects(for: self)
        onDividerDrag?(d.path, ratio)
    }

    override func mouseUp(with event: NSEvent) { dragging = nil }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
        let frames = tree?.frames(in: bounds, gap: Self.dividerWidth) ?? [:]
        for (id, container) in containers {
            if let frame = frames[id] {
                container.frame = frame
                container.isHidden = false
            } else {
                container.isHidden = true
            }
        }
        layoutDividers()
        emptyLabel.isHidden = tree != nil
        // Wrap inside the area, with side padding, at any width.
        let width = max(0, bounds.width - 2 * LoamTheme.space6)
        emptyLabel.preferredMaxLayoutWidth = width
        let height = ceil(emptyLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0)
        emptyLabel.frame = CGRect(x: LoamTheme.space6, y: (bounds.height - height) / 2, width: width, height: height)
    }
}
