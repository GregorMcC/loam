import AppKit
import LoamTerminal

/// Synthetic input for the driver. Keys and mouse clicks go through the
/// window, the same path that AppKit uses: key equivalents first, then
/// `sendEvent`, then the view's `keyDown` and `interpretKeyEvents`.
@MainActor
extension DriverApp {
    // US ANSI key codes. libghostty reads the physical key from the code.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
        ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",",
        ">": ".", "?": "/", "~": "`",
    ]

    enum Key {
        case returnKey, tab, delete, escape, up, down

        var code: UInt16 {
            switch self {
            case .returnKey: 36
            case .tab: 48
            case .delete: 51
            case .escape: 53
            case .up: 126
            case .down: 125
            }
        }

        var characters: String {
            switch self {
            case .returnKey: "\r"
            case .tab: "\t"
            case .delete: "\u{7F}"
            case .escape: "\u{1B}"
            case .up: "\u{F700}"
            case .down: "\u{F701}"
            }
        }
    }

    /// Types the text one key at a time.
    func type(_ text: String) throws {
        for character in text {
            var base = Character(character.lowercased())
            var flags: NSEvent.ModifierFlags = character.isUppercase ? [.shift] : []
            if let unshifted = Self.shifted[character] {
                base = unshifted
                flags = [.shift]
            }
            guard let code = Self.keyCodes[base] else { throw DriverFailure("no key code for \(character)") }
            press(code: code, characters: String(character), ignoringModifiers: String(base), flags: flags)
        }
    }

    func press(_ key: Key, flags: NSEvent.ModifierFlags = []) {
        press(code: key.code, characters: key.characters, ignoringModifiers: key.characters, flags: flags)
    }

    /// Presses a letter key with modifiers, such as command-V or control-U.
    func press(letter: Character, flags: NSEvent.ModifierFlags) {
        let code = Self.keyCodes[letter]!
        var characters = String(letter)
        if flags.contains(.control), let ascii = letter.asciiValue {
            characters = String(UnicodeScalar(ascii & 0x1F))
        }
        press(code: code, characters: characters, ignoringModifiers: String(letter), flags: flags)
    }

    private func press(code: UInt16, characters: String, ignoringModifiers: String, flags: NSEvent.ModifierFlags) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers,
                isARepeat: false, keyCode: code) else { continue }
            deliver(event)
        }
    }

    /// The path that NSApplication.sendEvent takes for a key in the key window.
    private func deliver(_ event: NSEvent) {
        if event.type == .keyDown, !event.modifierFlags.isDisjoint(with: [.command, .control]),
           window.performKeyEquivalent(with: event) {
            return
        }
        window.sendEvent(event)
    }

    // MARK: Mouse

    /// The centre of a grid cell, in window coordinates. The driver config
    /// has no padding, so cell (0, 0) is at the top left of the view.
    func windowPoint(_ pane: TerminalSurfaceView, column: Double, row: Double) throws -> NSPoint {
        guard let size = pane.size, size.cell_width_px > 0 else { throw DriverFailure("the pane has no size") }
        let scale = window.backingScaleFactor
        let x = (column + 0.5) * Double(size.cell_width_px) / scale
        let y = (row + 0.5) * Double(size.cell_height_px) / scale
        return pane.convert(NSPoint(x: x, y: pane.bounds.height - y), to: nil)
    }

    func mouse(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        // Not window.sendEvent: when the window is not key (you use another
        // app during the run), AppKit waits on the real event queue to see if
        // a first click drags the window. Route by hit test, as AppKit does.
        guard let view = window.contentView?.hitTest(window.contentView!.convert(point, from: nil)) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .mouseMoved: view.mouseMoved(with: event)
        default: break
        }
    }

    /// A scroll event as a trackpad sends it. Positive `pixels` scrolls up.
    func scroll(_ pane: TerminalSurfaceView, pixels: Int32, phase: Int64 = 0, momentum: Int64 = 0) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0)
        else { return }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        guard let event = NSEvent(cgEvent: cg) else { return }
        pane.scrollWheel(with: event)
    }

    // MARK: Waits

    /// Waits until the condition is true, or fails after the timeout.
    func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { throw DriverFailure("timed out after \(Int(timeout)) s: \(what)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Log.line(String(format: "ok after %.2f s: %@", Date().timeIntervalSince(start), what))
    }

    func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Waits for a shell prompt: the screen ends in "% " or "$ " and stays still.
    func waitForPrompt(_ pane: TerminalSurfaceView, timeout: TimeInterval = 10) async throws {
        var last = ""
        var still = 0
        try await waitUntil("prompt in \(pane.identifier?.rawValue ?? "?")", timeout: timeout) {
            let text = pane.screenText()
            let trimmed = lines(pane).last(where: { !$0.isEmpty }) ?? ""
            still = text == last ? still + 1 : 0
            last = text
            return still >= 3 && (trimmed.hasSuffix("%") || trimmed.hasSuffix("$") || trimmed.hasSuffix("#"))
        }
    }

    /// The lines of the screen with trailing spaces removed.
    func lines(_ pane: TerminalSurfaceView, all: Bool = false) -> [String] {
        (all ? pane.allText() : pane.screenText()).split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
    }

    /// True when the screen changes on each of 3 checks, 200 ms apart.
    func isStreaming(_ pane: TerminalSurfaceView) async -> Bool {
        var previous = pane.screenText()
        for _ in 0..<3 {
            await sleep(0.2)
            let now = pane.screenText()
            if now == previous { return false }
            previous = now
        }
        return true
    }
}
