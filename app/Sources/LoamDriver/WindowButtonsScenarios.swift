import AppKit
import LoamKit

/// The check of ticket 133: the window buttons and the title bar while a sheet shows. Under a native sheet, macOS turns the close
/// button off. The minimize button and the zoom button stay on, and a double click on the title bar still zooms the window or
/// minimizes it, as the system setting says. A sheet of Loam has to do the same, and so has a window with no sheet.
@MainActor
extension Scenarios {
    /// Counts the questions "may the window close?" and answers no, so a press on the close button never ends the app. Every
    /// other call goes on to the window controller.
    private final class CloseSpy: NSObject, NSWindowDelegate {
        private let original: NSWindowDelegate?
        private(set) var asked = 0

        init(original: NSWindowDelegate?) { self.original = original }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            asked += 1
            return false
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || ((original as? NSObject)?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? { original }
    }

    /// A click as the system sends it: the press and the release go on the event queue of the app, and the app takes them to the
    /// window. The pointer of the system does not move, and no app becomes active. The caller waits for what the click does.
    private static func postClick(_ host: AppHost, at point: NSPoint, count: Int = 1, flags: NSEvent.ModifierFlags = []) {
        for number in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: number,
                    pressure: type == .leftMouseUp ? 0 : 1) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// Where the window server has the window, in the coordinates of AppKit. It follows `window.frame` a moment after a change of the
    /// frame. A press that is posted before that lands at a wrong point of the window: the shift is the difference of the two frames.
    private static func windowServerFrame(of window: NSWindow) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]],
              let dictionary = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
              let screen = NSScreen.screens.first else { return nil }
        return NSRect(x: bounds.minX, y: screen.frame.height - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    private static func windowServerHasFrame(_ window: NSWindow) -> Bool {
        guard let server = windowServerFrame(of: window) else { return false }
        let frame = window.frame
        return [server.minX - frame.minX, server.minY - frame.minY, server.width - frame.width, server.height - frame.height]
            .allSatisfy { abs($0) < 1 }
    }

    private static func windowButton(_ host: AppHost, _ type: NSWindow.ButtonType) throws -> NSButton {
        guard let button = host.window.standardWindowButton(type) else { throw DriverFailure("the window has no button \(type)") }
        return button
    }

    /// The centre of a view, in the coordinates of the window.
    private static func windowCentre(of view: NSView) -> NSPoint {
        let box = view.convert(view.bounds, to: nil)
        return NSPoint(x: box.midX, y: box.midY)
    }

    /// A point of the title bar where a press lands on no control: the first one, from the New session button toward the title,
    /// that is not over a window button, a toolbar item or the title itself.
    private static func emptyTitleBarPoint(_ host: AppHost) throws -> NSPoint {
        guard let frame = host.window.contentView?.superview, let item = find("new-session-button", in: frame) else {
            throw DriverFailure("the window has no New session button")
        }
        let box = item.convert(item.bounds, to: nil)
        for step in stride(from: 40.0, through: 400.0, by: 40.0) {
            let point = NSPoint(x: box.minX - step, y: box.midY)
            var view = frame.hitTest(point)
            var onControl = false
            while let current = view {
                onControl = onControl || current is NSControl
                view = current.superview
            }
            if !onControl { return point }
        }
        throw DriverFailure("the title bar has no point with no control, left of the New session button")
    }

    /// What `AppleActionOnDoubleClick` says about a double click on the title bar: "Maximize" (shown as Zoom, and the default
    /// when the key is not set), "Minimize", or another value. The check reads it and never changes it.
    private static var doubleClickAction: String {
        UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
    }

    /// The window buttons and the title bar, in the state that macOS has under a native sheet. `sheetShows` is true while a
    /// sheet of Loam or a native sheet is on the window: the close button is off then and refuses a press. The other two buttons
    /// are on. A sheet takes full screen away, so a click on the zoom button zooms the window, as an Option-click does, and so
    /// does a double click on the title bar. With no sheet, the zoom button goes to full screen, so only the Option-click
    /// is pressed. Each press puts the window back as it was. A double click that minimizes (the setting) is not pressed: it
    /// would hide the window.
    static func expectWindowButtons(_ app: DriverApp, _ host: AppHost, sheetShows: Bool, _ state: String) async throws {
        let window = host.window
        let original = window.delegate
        let spy = CloseSpy(original: original)
        window.delegate = spy
        defer { window.delegate = original }
        var wrong: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { wrong.append(message) } }

        let close = try windowButton(host, .closeButton), mini = try windowButton(host, .miniaturizeButton)
        let zoom = try windowButton(host, .zoomButton)
        func word(_ on: Bool) -> String { on ? "on" : "off" }
        check(close.isEnabled == !sheetShows, "the close button is \(word(close.isEnabled)), and macOS has it \(word(!sheetShows))")
        check(mini.isEnabled, "the minimize button is off")
        check(zoom.isEnabled, "the zoom button is off")
        let frame = window.frame
        let before = (sheetOpen: host.model.sheetIsOpen, native: window.attachedSheet != nil)
        func waitForWindowServer() async throws {
            try await app.waitUntil("the window server has the frame of the window") { windowServerHasFrame(window) }
        }
        func putBack() async throws {
            window.setFrame(frame, display: true)
            try await app.waitUntil("the window is as it was") { window.frame == frame && !window.isZoomed }
            try await waitForWindowServer()
        }

        // A press that is posted while the window server has an older frame lands at a wrong point. The scenario sets a frame before
        // the first press, and each press that zooms changes it. So the first press and each put back wait for the window server.
        try await waitForWindowServer()

        // An Option-click on the zoom button zooms the window, also under a sheet.
        postClick(host, at: windowCentre(of: zoom), flags: .option)
        try await app.waitUntil("an Option-click on the zoom button zooms the window") { window.isZoomed }
        try await putBack()

        // A plain click on the zoom button: under a sheet, the window zooms (macOS has no full screen then). A window that
        // goes to full screen leaves it again at once, so a failure does not keep the display.
        var zoomedByClick: Bool?
        if sheetShows {
            postClick(host, at: windowCentre(of: zoom))
            try await app.waitUntil("a click on the zoom button zooms the window or goes to full screen") {
                window.isZoomed || window.styleMask.contains(.fullScreen)
            }
            let fullScreen = window.styleMask.contains(.fullScreen)
            zoomedByClick = window.isZoomed
            check(!fullScreen, "a click on the zoom button went to full screen")
            if fullScreen {
                window.toggleFullScreen(nil)
                try await app.waitUntil("the window leaves full screen") { !window.styleMask.contains(.fullScreen) }
            }
            try await putBack()
        }

        // A double click on the title bar does what the setting says. The check presses it for Zoom only.
        let action = doubleClickAction
        var zoomedByTitleBar: Bool?
        if action == "Maximize" {
            try postClick(host, at: emptyTitleBarPoint(host), count: 2)
            try await app.waitUntil("a double click on the title bar zooms the window") { window.isZoomed }
            zoomedByTitleBar = true
            try await putBack()
        }

        // A press on the close button: the window is asked to close with no sheet, and it is not asked under a sheet. A press that
        // macOS ignores does nothing, so a pause stands for the wait.
        postClick(host, at: windowCentre(of: close))
        await app.sleep(0.5)
        check(spy.asked == (sheetShows ? 0 : 1), "a press on the close button asked the window to close \(spy.asked) times")

        check(window.frame == frame && !window.isZoomed && !window.isMiniaturized && !window.styleMask.contains(.fullScreen),
              "the window is not as it was")
        check(host.model.sheetIsOpen == before.sheetOpen && (window.attachedSheet != nil) == before.native, "a press closed or opened a sheet")
        // A close that does not come from the button is refused under a sheet too. A window that agreed would quit the app.
        if sheetShows { check(original?.windowShouldClose?(window) == false, "the window agreed to close under the sheet") }
        func outcome(_ value: Bool?) -> String { value.map { $0 ? "zooms" : "does nothing" } ?? "not pressed" }
        Log.line("window buttons, \(state): close \(word(close.isEnabled)), minimize \(word(mini.isEnabled)), zoom \(word(zoom.isEnabled)), "
                 + "close asked \(spy.asked), Option-click zooms, click \(outcome(zoomedByClick)), "
                 + "double click (\(action)) \(outcome(zoomedByTitleBar))")
        if !wrong.isEmpty { throw DriverFailure("the window buttons \(state) differ from macOS:\n- " + wrong.joined(separator: "\n- ")) }
    }
}
