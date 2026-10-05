import AppKit
import LoamKit

/// The bar at the bottom of a seeded pane after its process exits (spec 8.2): "Session ended",
/// with keys to resume, start a new session, or close. It takes the keys while it shows, so no
/// key reaches the ended terminal (libghostty closes an ended surface on any key).
/// Return resumes, N starts a new session, and ⌘W closes, through the menu as for any pane.
final class SessionEndedBar: NSView {
    private var paletteObserver: ChromePaletteObserver?
    static let height: CGFloat = 30

    var onResume: (() -> Void)?
    var onNewSession: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "Session ended")
    private let resumeButton = NSButton(title: "Resume \u{23CE}", target: nil, action: nil)
    private let newButton = NSButton(title: "New session N", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close \u{2318}W", target: nil, action: nil)

    /// A line after "Session ended", for example that the worktree is gone. Nil shows the plain bar.
    var note: String? {
        didSet {
            guard note != oldValue else { return }
            label.stringValue = note.map { "Session ended. \($0)" } ?? "Session ended"
            label.toolTip = note
            setAccessibilityLabel(label.stringValue)
            needsLayout = true
        }
    }

    /// Resume needs a session that started. A pane whose `loam start` failed can only start again.
    var canResume = true {
        didSet { resumeButton.isHidden = !canResume }
    }

    init(paneID: PaneID) {
        super.init(frame: .zero)
        wantsLayer = true
        paletteObserver = observeChromePalette { [weak self] _ in self?.applyColors() }
        label.font = LoamTheme.font(LoamTheme.captionStyle)
        label.textColor = LoamTheme.ink
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        applyColors()
        let id = paneID.uuidString
        for (button, action, name) in [
            (resumeButton, #selector(resume), "pane-resume-\(id)"),
            (newButton, #selector(newSession), "pane-new-session-\(id)"),
            (closeButton, #selector(closePane), "pane-close-\(id)"),
        ] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.target = self
            button.action = action
            button.refusesFirstResponder = true
            button.setAccessibilityIdentifier(name)
            addSubview(button)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Session ended")
        setAccessibilityIdentifier("pane-ended-\(id)")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The bar stands on `horizon-o` at the window alpha, as the pane header does.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = LoamTheme.ground(LoamTheme.horizonO).cgColor
        }
    }

    override func layout() {
        super.layout()
        var x = bounds.width - 8
        for button in [closeButton, newButton, resumeButton] where !button.isHidden {
            button.sizeToFit()
            x -= button.frame.width
            button.frame.origin = CGPoint(x: x, y: (bounds.height - button.frame.height) / 2)
            x -= 6
        }
        label.sizeToFit()
        label.frame.size.width = min(label.frame.width, max(0, x - 10))
        label.frame.origin = CGPoint(x: 10, y: (bounds.height - label.frame.height) / 2)
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return super.keyDown(with: event) }
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (36, _), (76, _): if canResume { resume() }  // Return, keypad Enter.
        case (_, "n"): newSession()
        default: break  // Every other key stays here and never reaches the ended terminal.
        }
    }

    @objc private func resume() { onResume?() }
    @objc private func newSession() { onNewSession?() }
    @objc private func closePane() { onClose?() }
}
