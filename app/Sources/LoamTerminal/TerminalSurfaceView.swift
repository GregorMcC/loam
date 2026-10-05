// The key, IME, mouse, and scroll handling in this file is ported from Ghostty's
// macOS host layer (macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift)
// at the commit in ghostty.pin, and grown from the Loam libghostty spike.
//
// MIT License
//
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import AppKit
import GhosttyKit
import LoamKit
import OSLog

public enum TerminalError: Error {
    case surfaceFailed
}

/// One pane: an NSView that hosts one libghostty surface. libghostty runs the
/// PTY, parses the output, and draws into its own Metal layer on this view.
/// The view feeds it size, scale, focus, keys, IME, mouse, and scroll.
///
/// Close a pane only with `close(completion:)`. It runs the safe close order.
@MainActor
public final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
    let runtime: TerminalRuntime
    /// Nil after the close frees it.
    public private(set) var surface: ghostty_surface_t?

    public internal(set) var title = "" { didSet { if title != oldValue { onTitleChange?(title) } } }
    public var onTitleChange: ((String) -> Void)?
    /// The pane's process exited, with its exit code. The pane stays open.
    public var onChildExited: ((Int32) -> Void)?
    /// True when the owner shows its own view after the process exits. libghostty then does not
    /// print "Process exited. Press any key to close the terminal." Any key still closes the
    /// surface, so the owner must keep keys away from the view.
    public var replacesExitMessage = false
    /// libghostty asks to close the pane, for example after the shell exits.
    /// The owner closes it with `close(completion:)`. `processAlive` is true
    /// when a process still runs.
    public var onCloseRequest: ((_ processAlive: Bool) -> Void)?
    public var onBell: (() -> Void)?
    /// You typed in the terminal: a key with no command key that `TypingKey` counts as typing.
    /// Loam clears "needs you" on it, because a denied permission prompt sends no hook (spec 8.4).
    public var onKeyInput: (() -> Void)?
    public var onDesktopNotification: ((_ title: String, _ body: String) -> Void)?
    /// Called when a clipboard request shows its prompt. The driver uses it.
    public var onClipboardConfirmation: ((ClipboardConfirmation) -> Void)?

    /// The clipboard request that waits for an answer, if any.
    public private(set) var pendingClipboardConfirmation: ClipboardConfirmation?

    var cellSizeInPixels = NSSize.zero
    private var focused = false
    private var markedText = NSMutableAttributedString()
    /// Non-nil only inside keyDown: the text the input method committed.
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var observers: [NSObjectProtocol] = []

    private var closer: SafeClose?
    private var closeTimer: Timer?
    private var closeCompletions: [(CloseResult) -> Void] = []

    /// What a close did. The driver logs it.
    public struct CloseResult: Sendable {
        /// Seconds from the SIGHUP to the process exit.
        public var waited: TimeInterval
        /// Seconds that `ghostty_surface_free` took.
        public var free: TimeInterval
        /// The signals sent, as "HUP 123" or "KILL 123".
        public var signals: [String]
        /// True when the process did not exit and the free came from the deadline.
        public var forced: Bool
    }

    /// Makes the pane and starts its process. A nil `spec.command` starts your
    /// login shell. `spec.env` adds to the clean app environment (spec 8.2).
    public init(runtime: TerminalRuntime, spec: PaneSpec) throws {
        self.runtime = runtime
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // Keep every C string alive until ghostty_surface_new returns.
        let keys = spec.env.keys.sorted()
        let cKeys = keys.map { strdup($0) }
        let cValues = keys.map { strdup(spec.env[$0]!) }
        defer { (cKeys + cValues).forEach { free($0) } }
        var envVars = zip(cKeys, cValues).map { ghostty_env_var_s(key: $0, value: $1) }
        let command = spec.command.map { strdup($0) } ?? nil
        let folder = spec.folder.map { strdup($0) } ?? nil
        defer { free(command); free(folder) }

        surface = envVars.withUnsafeMutableBufferPointer { buffer in
            config.command = UnsafePointer(command)
            config.working_directory = UnsafePointer(folder)
            config.env_vars = buffer.baseAddress
            config.env_var_count = buffer.count
            return ghostty_surface_new(runtime.app, &config)
        }
        guard surface != nil else { throw TerminalError.surfaceFailed }
        Self.live[UInt(bitPattern: config.userdata)] = Weak(self)
        updateTrackingAreas()
        registerForDraggedTypes(Array(Self.dropTypes))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private struct Weak {
        weak var view: TerminalSurfaceView?
        init(_ view: TerminalSurfaceView) { self.view = view }
    }

    /// The views with a live surface, by userdata address. A callback that
    /// libghostty queued before the free finds nothing here, so it never
    /// touches a freed view.
    private static var live: [UInt: Weak] = [:]

    static func from(_ userdata: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        live[UInt(bitPattern: userdata)]?.view
    }

    private static let keyLog = Logger(subsystem: "dev.loam.Loam", category: "keys")

    /// Every view with a live surface.
    static var liveViews: [TerminalSurfaceView] { live.values.compactMap(\.view) }

    // MARK: Close

    /// True from the start of the close.
    public var isClosing: Bool { closer != nil }

    /// Closes the pane with the safe order (spec 8.2): SIGHUP to the foreground
    /// process group, run the run loop until the process exits and every group
    /// that got a SIGHUP is gone (SIGKILL after 2 s), then `ghostty_surface_free`.
    /// The completion runs after the free.
    /// A second call adds its completion to the running close.
    public func close(completion: ((CloseResult) -> Void)? = nil) {
        if let completion { closeCompletions.append(completion) }
        guard closer == nil else { return }
        guard surface != nil else {
            finishClose(CloseResult(waited: 0, free: 0, signals: [], forced: false))
            return
        }
        closer = SafeClose(startedAt: ProcessInfo.processInfo.systemUptime)
        closeSignals = []
        closeStep()
        guard surface != nil else { return }
        // A timer in the common modes keeps the close going during menus and sheets.
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeStep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        closeTimer = timer
    }

    private var closeSignals: [String] = []

    private func closeStep() {
        guard let surface, var closer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let group = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
        let steps = closer.next(now: now, foreground: group > 0 ? group : nil,
                                exited: ghostty_surface_process_exited(surface),
                                groupAlive: { killpg($0, 0) == 0 || errno == EPERM })
        self.closer = closer
        for step in steps {
            switch step {
            case .signal(let group, let signal):
                killpg(group, signal)
                closeSignals.append("\(signal == SIGKILL ? "KILL" : "HUP") \(group)")
            case .free:
                let waited = now - closer.startedAt
                let free = freeSurface()
                finishClose(CloseResult(waited: waited, free: free, signals: closeSignals, forced: closer.forced))
            }
        }
    }

    private func freeSurface() -> TimeInterval {
        guard let surface else { return 0 }
        // A pending prompt holds libghostty state. Deny it before the free.
        pendingClipboardConfirmation?.respond(false)
        pendingClipboardConfirmation = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        let start = ProcessInfo.processInfo.systemUptime
        ghostty_surface_free(surface)
        self.surface = nil
        Self.live[UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())] = nil
        return ProcessInfo.processInfo.systemUptime - start
    }

    private func finishClose(_ result: CloseResult) {
        closeTimer?.invalidate()
        closeTimer = nil
        let completions = closeCompletions
        closeCompletions = []
        completions.forEach { $0(result) }
    }

    func libghosttyRequestedClose(processAlive: Bool) {
        guard surface != nil, !isClosing else { return }
        onCloseRequest?(processAlive)
    }

    // MARK: Reads

    /// The text of the visible screen.
    public func screenText() -> String {
        readText(GHOSTTY_POINT_VIEWPORT)
    }

    /// The text of the whole screen, scrollback included.
    public func allText() -> String {
        readText(GHOSTTY_POINT_SCREEN)
    }

    private func readText(_ tag: ghostty_point_tag_e) -> String {
        guard let surface else { return "" }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// The selected text, or nil when nothing is selected.
    public func selectionText() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// The grid and cell size, in pixels.
    public var size: ghostty_surface_size_s? {
        surface.map { ghostty_surface_size($0) }
    }

    /// The foreground process group of the pane's terminal, or 0.
    public var foregroundProcessGroup: pid_t {
        surface.map { pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid($0)) } ?? 0
    }

    public var processExited: Bool {
        surface.map { ghostty_surface_process_exited($0) } ?? true
    }

    /// Runs a Ghostty binding action, such as "copy_to_clipboard".
    @discardableResult
    public func perform(action: String) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: Clipboard prompt

    func present(_ request: ClipboardConfirmation) {
        pendingClipboardConfirmation?.respond(false)
        guard let window else {
            request.respond(false)
            return
        }
        pendingClipboardConfirmation = request
        request.onAnswered = { [weak self, weak request] in
            if let self, self.pendingClipboardConfirmation === request { self.pendingClipboardConfirmation = nil }
        }
        request.show(on: window)
        onClipboardConfirmation?(request)
    }

    // MARK: Size, scale, screen

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pushSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncFocus() }
            })
        }
        observers.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.screenDidChange() } })
        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let surface = self.surface, let window = self.window else { return }
                ghostty_surface_set_occlusion(surface, self.runtime.assumesKeyAndVisible || window.occlusionState.contains(.visible))
            }
        })
        screenDidChange()
    }

    private func screenDidChange() {
        guard let surface, let screen = window?.screen else { return }
        if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(surface, id.uint32Value)
        }
        viewDidChangeBackingProperties()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            // libghostty scales the content. Stop the compositor from scaling it too.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let backing = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, backing.width / frame.width, backing.height / frame.height)
        pushSize()
    }

    private func pushSize() {
        guard let surface else { return }
        let backing = convertToBacking(bounds.size)
        guard backing.width >= 1, backing.height >= 1 else { return }
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
    }

    // MARK: Focus

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focused = true; syncFocus() }
        return result
    }

    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focused = false; syncFocus() }
        return result
    }

    private func syncFocus() {
        guard let surface else { return }
        let key = runtime.assumesKeyAndVisible ? window != nil : window?.isKeyWindow ?? false
        ghostty_surface_set_focus(surface, focused && key)
    }

    // MARK: Mouse

    /// A drag in the pane selects text. It must never move the window.
    public override var mouseDownCanMoveWindow: Bool { false }

    public override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, frame.height - point.y, Input.mods(event.modifierFlags))
    }

    public override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let surface else { return }
        sendMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Input.mods(event.modifierFlags))
    }

    public override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Input.mods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Input.mods(event.modifierFlags))
        else { return super.rightMouseDown(with: event) }
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Input.mods(event.modifierFlags))
        else { return super.rightMouseUp(with: event) }
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, Input.mouseButton(event.buttonNumber), Input.mods(event.modifierFlags))
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, Input.mouseButton(event.buttonNumber), Input.mods(event.modifierFlags))
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // Reset the position. libghostty keeps -1, -1 after the mouse leaves.
        sendMousePosition(event)
    }

    public override func mouseExited(with event: NSEvent) {
        // A drag keeps sending positions after the mouse leaves the view.
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Input.mods(event.modifierFlags))
    }

    public override func mouseMoved(with event: NSEvent) { sendMousePosition(event) }
    public override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }
    public override func rightMouseDragged(with event: NSEvent) { sendMousePosition(event) }
    public override func otherMouseDragged(with event: NSEvent) { sendMousePosition(event) }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            // Ghostty doubles trackpad deltas. It feels closer to native scroll.
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, Input.scrollMods(precise: precise, momentum: event.momentumPhase))
    }

    public override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor? = switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB: .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: .closedHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE: .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE: .resizeUpDown
        default: nil
        }
        cursor?.set()
    }

    // MARK: Keys

    public override func keyDown(with event: NSEvent) {
        if !event.modifierFlags.contains(.command), TypingKey.clearsNeedsYou(event.characters) { onKeyInput?() }
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Options such as macos-option-as-alt change the modifiers that
        // translate the key to text. Set only the four flags: the event holds
        // hidden bits that dead keys need.
        let translationGhostty = Input.flags(ghostty_surface_key_translation_mods(surface, Input.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationGhostty.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        // Reuse the same event object when nothing changed. Korean input needs it.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0
        let layoutBefore = markedTextBefore ? nil : Input.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // The key switched the keyboard layout. An input method took it.
        if !markedTextBefore && layoutBefore != Input.keyboardLayoutID { return }

        syncPreedit(clearIfNeeded: markedTextBefore)
        // A key that ends a composition is part of the composition.
        let composing = markedText.length > 0 || markedTextBefore

        if markedTextBefore, let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControl(text, composing: composing) {
                _ = committedText(action, text)
            }
            if shouldReplayCommittedPreeditKey(translationEvent) {
                _ = keyAction(action, event: event, translationEvent: translationEvent)
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControl(text, composing: composing) {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if Self.isComposingControl(event.characters, composing: composing) { return }
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: translationEvent.ghosttyCharacters, composing: composing)
        }
    }

    public override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    public override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let mods = Input.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            // A press of the right-side key only counts when that side is down.
            let raw = event.modifierFlags.rawValue
            let sidePressed = switch event.keyCode {
            case 0x3C: raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    /// Command and control keys come here first. A fixed Loam key goes to Loam and never
    /// to libghostty, so it wins over your config (spec 8.3). A Ghostty binding goes to the
    /// menu first, so a menu key runs the same handler, then to the terminal.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }

        // Loam owns its fixed keys, so a key stays out of the terminal even when its command does
        // nothing yet (the switcher and "needs you" come in later tickets). With no handler at
        // all (a runtime with no window), the key takes the normal path.
        if let handler = runtime.commandHandler, let chord = KeyChord(event: event),
           case .loam(let command) = LoamKeys.route(chord, isGhosttyBinding: false) {
            if !handler(command) {
                Self.keyLog.info("Loam key \(chord.description, privacy: .public) did nothing")
            }
            return true
        }

        var key = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { pointer in
            key.text = pointer
            return ghostty_surface_key_is_binding(surface, key, &flags)
        }
        if isBinding {
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass control-Return through. Stop the default menu equivalent.
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // Control-/ beeps in AppKit. Send it as control-_.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            // AppKit makes some synthetic events with no timestamp. Skip them.
            if event.timestamp == 0 { return false }
            guard !event.modifierFlags.isDisjoint(with: [.command, .control]) else {
                lastPerformKeyEvent = nil
                return false
            }
            // The second pass of the same event goes to keyDown. See doCommand.
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let final = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: final)
        return true
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var key = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        key.composing = composing
        guard let text = text?.keyEventText else { return ghostty_surface_key(surface, key) }
        return text.withCString { pointer in
            key.text = pointer
            return ghostty_surface_key(surface, key)
        }
    }

    /// Text that an input method committed, sent as typed input with no key.
    private func committedText(_ action: ghostty_input_action_e, _ text: String) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        return text.withCString { pointer in
            key.text = pointer
            return ghostty_surface_key(surface, key)
        }
    }

    private func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7D, 0x7C, 0x7E: return true // down, right, up
        case 0x7B: // left: Korean input methods already leave the caret in place
            return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default: return false
        }
    }

    /// A single C0 control character while composing belongs to the input method.
    static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else {
            return false
        }
        return scalar.value < 0x20
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let text = markedText.string
            text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: Edit menu

    @objc public func copy(_ sender: Any?) { perform(action: "copy_to_clipboard") }
    @objc public func paste(_ sender: Any?) { perform(action: "paste_from_clipboard") }
    @objc public func pasteAsPlainText(_ sender: Any?) { perform(action: "paste_from_clipboard") }
    @objc public override func selectAll(_ sender: Any?) { perform(action: "select_all") }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): surface.map { ghostty_surface_has_selection($0) } ?? false
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)): runtime.pasteboard.loamString() != nil
        default: true
        }
    }

    // MARK: NSTextInputClient

    public func hasMarkedText() -> Bool { markedText.length > 0 }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    public func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
        case let value as String: markedText = NSMutableAttributedString(string: value)
        default: return
        }
        // Outside keyDown (for example a layout change mid-composition), show it now.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    public func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.length > 0, let selection = selectionText() else { return nil }
        return NSAttributedString(string: selection)
    }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        // libghostty knows where the cursor is, so the input method window
        // shows next to it. Its points have the origin top left.
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let scale = window?.backingScaleFactor ?? 1
        let cellWidth = cellSizeInPixels.width / scale
        if range.length == 0, width > 0 {
            width = 0
            x += cellWidth * Double(range.location + range.length)
        }
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: width, height: max(height, cellSizeInPixels.height / scale))
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        // Ghostty also needs a current event here. Loam does not, so the driver
        // can commit text the way an input method does.
        let text: String
        switch string {
        case let value as NSAttributedString: text = value.string
        case let value as String: text = value
        default: return
        }
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }
        // Committed text (input method, dictation) goes as typed keys, never as a paste.
        if !text.isEmpty { _ = committedText(GHOSTTY_ACTION_PRESS, text) }
    }

    /// Stops the beep for commands that the view does not handle. A command
    /// key that came back from performKeyEquivalent goes to keyDown again.
    public override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }
}

// MARK: Drop

extension TerminalSurfaceView {
    /// What a pane takes in a drop, as in Ghostty: files and text.
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [.string, .fileURL]

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types, !Set(types).isDisjoint(with: Self.dropTypes) else { return [] }
        return .copy  // The copy cursor, as Ghostty shows.
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        drop(sender.draggingPasteboard)
    }

    /// Pastes the dropped items into the pane, as Ghostty does: a file is its shell-escaped path,
    /// and several items are joined with spaces. libghostty sends it as a paste (bracketed when the
    /// program asks), so Claude Code attaches a dropped image from its path. As in Ghostty, a drop
    /// skips the unsafe-paste prompt: the drag is the confirmation.
    @discardableResult
    public func drop(_ pasteboard: NSPasteboard) -> Bool {
        guard let text = pasteboard.loamString(), !text.isEmpty else { return false }
        DispatchQueue.main.async { [weak self] in self?.sendText(text) }
        return true
    }

    /// Sends text to the program as a paste.
    func sendText(_ text: String) {
        guard let surface else { return }
        let length = text.utf8.count
        guard length > 0 else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(length)) }
    }
}
