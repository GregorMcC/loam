import AppKit
import LoamKit

/// The seam between the layout and the terminal surface. The layout asks for one view per pane.
/// Ticket 25 provides a factory that returns `TerminalSurfaceView`. Until then the app uses the placeholder.
@MainActor
protocol PaneViewFactory {
    /// Builds the content view of a pane. The layout owns the view from here on and keeps it alive
    /// while the pane exists, also while its plot is hidden.
    func makeView(for spec: PaneSpec, id: PaneID) -> NSView

    /// Closes the pane's view. Call `completion` when the view is safe to remove. A terminal surface
    /// runs the safe close order (spec 8.2) first. The default completes at once.
    func closeView(_ view: NSView, completion: @escaping @MainActor () -> Void)
}

extension PaneViewFactory {
    func closeView(_ view: NSView, completion: @escaping @MainActor () -> Void) { completion() }
}

/// A flat view with the pane title, for the time before the terminal surface exists.
@MainActor
struct PlaceholderPaneViewFactory: PaneViewFactory {
    func makeView(for spec: PaneSpec, id: PaneID) -> NSView {
        PlaceholderPaneView(spec: spec)
    }
}

final class PlaceholderPaneView: NSView {
    private var paletteObserver: ChromePaletteObserver?
    init(spec: PaneSpec) {
        super.init(frame: .zero)
        wantsLayer = true
        paletteObserver = observeChromePalette { [weak self] _ in self?.applyColors() }
        applyColors()
        let label = NSTextField(labelWithString: "\(spec.kind.rawValue): \(spec.title)")
        label.textColor = LoamTheme.inkMuted
        label.font = LoamTheme.font(LoamTheme.codeStyle)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The placeholder stands on `bedrock`, as a terminal pane does.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = LoamTheme.ground(LoamTheme.bedrock).cgColor
        }
    }
}
