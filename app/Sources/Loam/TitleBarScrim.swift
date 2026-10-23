import AppKit
import LoamKit

/// The part of a sheet's scrim over the title bar (ticket 126). A native sheet dims the whole window: the title, the toolbar
/// glass and the sidebar button too. Only the window buttons keep their look. The toolbar draws over every overlay of the
/// window, so the scrim of a sheet (`SheetScrim`) stops under the title bar, and two views dim the rest. No point is dimmed twice.
///
/// - `bar` sits over the toolbar. It dims the title bar except the window buttons, and takes the clicks there: a click
///   closes the sheet like a click on the rest of the scrim, and a drag moves the window.
/// - `buttons` sits under the toolbar. It dims the ground behind the window buttons, and the buttons draw over it.
@MainActor
final class TitleBarScrim {
    let bar = TitleBarScrimView(part: .bar)
    let buttons = TitleBarScrimView(part: .windowButtons)
    private(set) var isShown = false
    private weak var content: NSView?

    init() {
        bar.setAccessibilityIdentifier("title-bar-scrim")
        buttons.setAccessibilityIdentifier("title-bar-scrim-buttons")
    }

    /// Adds the views to the window. `buttons` goes in the content view with the overlays, over `split`, so it sits under the
    /// title bar. `bar` goes in the frame of the window, the parent of the content view, as the top view, over the title bar.
    /// It ends where the safe area of the content begins (the edge where `SheetScrim` begins), so a toolbar that shows or hides,
    /// or a title bar that changes, lays it out again with no code of ours.
    func install(content: NSView, frame: NSView, above split: NSView) {
        self.content = content
        content.addSubview(buttons, positioned: .above, relativeTo: split)
        frame.addSubview(bar, positioned: .above, relativeTo: nil)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: frame.topAnchor),
            bar.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
        ])
    }

    /// Shows or hides the scrim. It fades in as the scrim of the sheet does, and goes at once, as the sheet does.
    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        guard shown else {
            for view in [bar, buttons] {
                view.isHidden = true
                view.alphaValue = 0
            }
            return
        }
        placeButtons()
        for view in [bar, buttons] {
            view.alphaValue = 0
            view.isHidden = false
        }
        let reduce = LoamMotion.reduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? LoamTheme.durationFast : LoamTheme.durationSlow
            context.timingFunction = reduce ? CAMediaTimingFunction(name: .linear) : LoamMotion.timingFunction(LoamTheme.easeSettle)
            bar.animator().alphaValue = 1
            buttons.animator().alphaValue = 1
        }
    }

    /// Puts `buttons` under the window buttons, and tells `bar` to leave them clear. The window buttons keep a place at the
    /// top left of the window, so a resize calls this. No window buttons, in full screen, leave nothing to clear.
    func placeButtons() {
        guard let content, let frame = bar.superview else { return }
        bar.clearRect = windowButtonsRect(in: frame)
        buttons.frame = windowButtonsRect(in: content) ?? .zero
    }

    /// The box around the three window buttons, in the coordinates of `view`, on whole pixels. Nil when they are not in the
    /// window (full screen puts them in the window of the toolbar).
    private func windowButtonsRect(in view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        let parts: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let found = parts.compactMap { window.standardWindowButton($0) }
        guard found.count == parts.count, found.allSatisfy({ $0.window === window && !$0.isHiddenOrHasHiddenAncestor }) else { return nil }
        let box = found.map { view.convert($0.bounds, from: $0) }.reduce(CGRect.null) { $0.union($1) }
        return view.backingAlignedRect(box, options: .alignAllEdgesOutward)
    }
}

extension MainWindowController {
    func installTitleBarScrim() {
        guard let split = splitController.splitView as? LoamSplitView, let content = split.superview,
              let frame = content.superview else { return }
        titleBarScrim.install(content: content, frame: frame, above: split)
        split.titleBarScrim = titleBarScrim
        // A click on the scrim closes the sheet. A sheet that holds the window (a merge or a start) ignores it.
        titleBarScrim.bar.onClick = { [weak self] in
            self?.model.closeLandSheet()
            self?.model.closeNewWorktree()
        }
    }

    /// Shows the scrim over the title bar while a sheet shows, with the sheets.
    func syncTitleBarScrim() {
        titleBarScrim.setShown(model.sheetIsOpen)
    }
}

/// One band of the scrim. It draws the scrim colour at the alpha of the sheet scrim, so the two meet with no seam.
final class TitleBarScrimView: NSView {
    enum Part { case bar, windowButtons }

    let part: Part
    /// For `bar`: runs on a click that is not a drag.
    var onClick: (() -> Void)?
    /// For `bar`: the box of the window buttons, in the coordinates of the frame that holds the bar. The bar leaves it clear.
    var clearRect: CGRect? {
        didSet { if clearRect != oldValue { needsDisplay = true } }
    }

    /// `clearRect` in the coordinates of the bar.
    private var clearBox: CGRect? { clearRect.map { convert($0, from: superview) } }

    init(part: Part) {
        self.part = part
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        isHidden = true
        alphaValue = 0
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        needsDisplay = true  // The hole follows the bar.
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            LoamTheme.scrim.withAlphaComponent(LoamTheme.scrimAlpha(dark: dark)).setFill()
            let path = NSBezierPath(rect: bounds)
            if part == .bar, let clear = clearBox {
                path.append(NSBezierPath(rect: clear))
                path.windingRule = .evenOdd
            }
            path.fill()
        }
    }

    // MARK: Clicks

    /// Only `bar` takes clicks, and not over the window buttons: they stay live.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard part == .bar, !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), !(clearBox?.contains(local) ?? false) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var dragged = false

    /// The view takes the press itself and hands a drag to the window (`mouseDragged`), so a click is not a drag.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { dragged = false }

    /// The first drag hands the press to the window, which moves while the pointer drags, as the title bar does.
    override func mouseDragged(with event: NSEvent) {
        guard !dragged else { return }
        dragged = true
        window?.performDrag(with: event)
    }

    /// A press with no drag is a click.
    override func mouseUp(with event: NSEvent) {
        if !dragged { onClick?() }
    }
}
