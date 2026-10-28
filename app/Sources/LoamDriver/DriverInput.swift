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
        case returnKey, tab, backtab, delete, escape, up, down

        var code: UInt16 {
            switch self {
            case .returnKey: 36
            case .tab, .backtab: 48
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
            case .backtab: "\u{19}"
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

    /// Presses a key. The back tab goes with Shift, as AppKit sends Shift-Tab.
    func press(_ key: Key, flags: NSEvent.ModifierFlags = []) {
        press(code: key.code, characters: key.characters, ignoringModifiers: key.characters,
              flags: key == .backtab ? flags.union(.shift) : flags)
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
            send(type, code: code, characters: characters, ignoringModifiers: ignoringModifiers, flags: flags, isARepeat: false)
        }
    }

    /// Puts marked text in the text field that has the keys, as an input method does while it composes (the default is the
    /// Japanese "nihon"), and returns the field editor. An Escape now belongs to the input method. A scenario ends the
    /// composition with `unmarkText()` when the Escape leaves it, since no input method runs in the driver.
    func compose(_ text: String = "\u{306B}\u{307B}\u{3093}") throws -> NSTextView {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
            throw DriverFailure("no text field has the keys")
        }
        editor.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        guard editor.hasMarkedText() else { throw DriverFailure("the text field took no marked text") }
        return editor
    }

    /// The label of the text field that has the keys, such as "Branch", or nil when no text field has them.
    func fieldWithTheKeys() -> String? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return (editor.delegate as? NSView)?.accessibilityLabel()
    }

    /// The SwiftUI view whose control has the keys: the root view of the hosting view that holds the first responder, such
    /// as "PRPopoverView" or "SidebarView". Nil when the window or a hosting view itself has the keys. A hosting view has
    /// them before SwiftUI gives them to one of its controls.
    func rootViewWithTheKeys() -> String? {
        var view = (window.firstResponder as? NSView)?.superview
        while let current = view {
            let name = String(describing: Swift.type(of: current))
            if name.hasPrefix("NSHostingView<") { return String(name.dropFirst("NSHostingView<".count).dropLast()) }
            view = current.superview
        }
        return nil
    }

    /// Presses a key that a SwiftUI button takes as its shortcut, such as ↓ on the Intake page or ] at the desk. AppKit
    /// offers every key down to the key equivalents of the window before the first responder sees it, and SwiftUI finds a
    /// shortcut there. So the key works whatever view has the keys, as a real key does. A key that no shortcut takes
    /// goes on to the first responder.
    func pressShortcut(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code) else { return }
        Log.line("shortcut \(characters.unicodeScalars.map { String($0.value, radix: 16) }.joined())")
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }

    /// Presses a key of `Key` as a shortcut. An arrow key comes with the flags that a real one has.
    func pressShortcut(_ key: Key) {
        pressShortcut(key.characters, code: key.code, flags: key == .up || key == .down ? [.numericPad, .function] : [])
    }

    /// Presses a letter or a sign, such as "j" or "]", as a shortcut.
    func pressShortcut(letter: Character) throws {
        guard let code = Self.keyCodes[letter] else { throw DriverFailure("no key code for \(letter)") }
        pressShortcut(String(letter), code: code)
    }

    /// One key down of a key that you hold: the first press, or with `isARepeat` a repeat that macOS sends while
    /// the key stays down. `keyUp` ends the hold.
    func keyDown(_ key: Key, isARepeat: Bool = false) {
        send(.keyDown, code: key.code, characters: key.characters, ignoringModifiers: key.characters, flags: [], isARepeat: isARepeat)
    }

    func keyUp(_ key: Key) {
        send(.keyUp, code: key.code, characters: key.characters, ignoringModifiers: key.characters, flags: [], isARepeat: false)
    }

    private func send(_ type: NSEvent.EventType, code: UInt16, characters: String, ignoringModifiers: String,
                      flags: NSEvent.ModifierFlags, isARepeat: Bool) {
        guard let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers,
            isARepeat: isARepeat, keyCode: code) else { return }
        deliver(event)
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

    /// A mouse event straight to `view`, as AppKit sends the drag and the release to the view that
    /// took the press, wherever the pointer is (ticket 98).
    func mouse(_ type: NSEvent.EventType, at point: NSPoint, on view: NSView) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: break
        }
    }

    /// Presses a mouse button other than the left and the right one at a point of the window, through the window's
    /// `sendEvent` as AppKit sends it. Button 3 is back and button 4 is forward (TAS-46). An event made from a CGEvent has
    /// no window, so its location is in screen coordinates.
    func otherMouseDown(button: Int, at point: NSPoint) {
        let screen = window.convertPoint(toScreen: point)
        let height = NSScreen.screens.first?.frame.height ?? 0
        guard let cg = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                               mouseCursorPosition: CGPoint(x: screen.x, y: height - screen.y), mouseButton: .center) else { return }
        cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        guard let event = NSEvent(cgEvent: cg) else { return }
        window.sendEvent(event)
    }

    /// Where the window server has the window, in the coordinates of AppKit. It follows `window.frame` a moment after a
    /// change of the frame.
    private func windowServerFrame() -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]],
              let dictionary = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
              let screen = NSScreen.screens.first else { return nil }
        return NSRect(x: bounds.minX, y: screen.frame.height - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    /// True when the window server has the frame that the window has. An event on the event queue of the app lands at a
    /// wrong point while the server still has an older frame: the shift is the difference of the two frames (ticket 133).
    func windowServerHasFrame() -> Bool {
        guard let server = windowServerFrame() else { return false }
        let frame = window.frame
        return [server.minX - frame.minX, server.minY - frame.minY, server.width - frame.width, server.height - frame.height]
            .allSatisfy { abs($0) < 1 }
    }

    /// A right mouse down on the event queue of the app, at a point of the window. AppKit shows the context menu of the
    /// view there, outside of the code of the scenario, so the scenario goes on while the menu is open (ticket 113). No
    /// mouse up follows, since a mouse up over the menu would pick the item under it. The press waits until the window
    /// server has the frame of the window, so a move or a resize before it does not shift the press (ticket 134).
    func postRightMouseDown(at point: NSPoint) async throws {
        try await postMouseDown(.rightMouseDown, at: point)
    }

    /// A mouse down of the type on the event queue of the app, as `postRightMouseDown` posts it. A left mouse down on a
    /// pop-up button opens its menu.
    func postMouseDown(_ type: NSEvent.EventType, at point: NSPoint) async throws {
        try await waitUntil("the window server has the frame of the window") { windowServerHasFrame() }
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// A key through `NSApp.sendEvent`, so the app's local event monitors see it first, as they do
    /// for a real key. A drag watches for Escape that way (ticket 98).
    func pressThroughApp(_ key: Key) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
            isARepeat: false, keyCode: key.code) else { return }
        NSApp.sendEvent(event)
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

    /// Waits until the condition is true. The wait has no time limit of its own, as in the LoamKit tests (ticket 125): a
    /// busy machine makes the app slow, and a fixed limit then fails a scenario that is right. The time limit of the
    /// scenario ends a wait that never ends, and the FAIL line names the wait. With `timeout`, the wait fails after
    /// that time. Use it only for a wait that can never end, such as a `try?` wait for a scenario that goes on when the
    /// condition does not come, or for a test of a time that a person would notice (ticket 131).
    func waitUntil(_ what: String, timeout: TimeInterval? = nil, _ condition: () -> Bool) async throws {
        let start = Date()
        waiting = what
        defer { waiting = nil }
        while !condition() {
            if let timeout, Date().timeIntervalSince(start) > timeout { throw DriverFailure("timed out after \(Int(timeout)) s: \(what)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Log.line(String(format: "ok after %.2f s: %@", Date().timeIntervalSince(start), what))
    }

    /// Waits until the plot panel column has ended its slide. The model and `isCollapsed` of the column change at the press,
    /// but the column is at its place only after the slide (ticket 125).
    func waitForPanelSlide(_ host: AppHost) async throws {
        try await waitUntil("the plot panel column ends its slide") { !host.panelIsSliding() }
    }

    /// A fixed wait. Use it where a scenario gives the app time to do something that it must not do, or where a shot waits
    /// for an animation that shows no state. Never use it before a check that something happened: wait for that with
    /// `waitUntil` (ticket 134).
    func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Waits for a shell prompt: the screen ends in "% " or "$ " and stays still.
    func waitForPrompt(_ pane: TerminalSurfaceView, timeout: TimeInterval? = nil) async throws {
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
