import AppKit
import LoamKit
import LoamTerminal

/// The key sweep (TAS-52): every key of the app, sent through the event queue of the app as a real key is. The window must
/// be key, so the scenario runs with `LOAM_DRIVER_FOREGROUND=1`, and DriverTests does not run it. Each key logs SWEEP OK or
/// SWEEP BROKEN, and the scenario goes on after a broken key. At the end, a broken key fails the scenario.
@MainActor
final class KeySweep {
    let app: DriverApp
    private(set) var broken: [String] = []
    private(set) var passed: [String] = []

    /// Throws without `LOAM_DRIVER_FOREGROUND=1`: behind your windows, no key with ⌘ reaches the menu.
    init(_ app: DriverApp) throws {
        guard Driver.foreground else { throw DriverFailure("the key sweep needs LOAM_DRIVER_FOREGROUND=1") }
        self.app = app
    }

    static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "-": 27, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ",": 43, "n": 45, "m": 46,
        ".": 47,
        "\r": 36, "\t": 48, "\u{1B}": 53, "\u{F700}": 126, "\u{F701}": 125, " ": 49,
    ]

    /// The window that has the keys, or the main window.
    var keyWindow: NSWindow { NSApp.keyWindow ?? app.window }

    /// The first responder of the key window, for the log.
    var holder: String {
        guard let responder = keyWindow.firstResponder else { return "none" }
        var name = String(describing: Swift.type(of: responder))
        if let root = app.rootViewWithTheKeys() { name += " in \(root)" }
        if let field = app.fieldWithTheKeys() { name += " (field \(field))" }
        return name
    }

    /// Posts a key down and a key up on the event queue of the app. Each is a CGEvent, as a real key is: AppKit reads its
    /// characters from the keyboard layout, and a menu item matches it by its key, so ⌘⇧D finds an item with "d" and ⇧.
    func post(_ key: String, _ flags: NSEvent.ModifierFlags = []) {
        var flags = flags
        if ["\u{F700}", "\u{F701}"].contains(key) { flags.formUnion([.numericPad, .function]) }
        guard let code = Self.codes[key] else { preconditionFailure("the key sweep has no key code for \(key.debugDescription)") }
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let cg = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
            // The window under the event, as the window server sets it on a real key.
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(keyWindow.windowNumber))
            cg.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard let event = NSEvent(cgEvent: cg) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Types text, one posted key per character.
    func type(_ text: String) async {
        for character in text {
            let lower = String(character).lowercased()
            post(lower, character.isUppercase ? .shift : [])
        }
        await app.sleep(0.3)
    }

    /// A real click on the middle of an element of the main window: a mouse down and up on the event queue.
    func click(_ id: String) async throws {
        AccessibilityProbe.shared.rescan()
        try await app.waitUntil("\(id) stands in the window") { app.windowPoint(of: id) != nil }
        try await app.waitUntil("the window server has the frame") { app.windowServerHasFrame() }
        guard let point = app.windowPoint(of: id) else { throw DriverFailure("no element \(id)") }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
        await app.sleep(0.4)
        Log.line("real click \(id)")
    }

    /// Presses the key, then waits up to `timeout` for the effect, and logs the result.
    @discardableResult
    func check(_ surface: String, _ name: String, _ key: String, _ flags: NSEvent.ModifierFlags = [],
               timeout: Double = 2, _ effect: () -> Bool) async -> Bool {
        // A key with ⌘ goes to the menu only while the app is active. Another app can take the front during a run.
        for _ in 0..<20 where !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            await app.sleep(0.1)
        }
        let before = holder + (NSApp.isActive ? "" : ", app not active")
        post(key, flags)
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            await app.sleep(0.05)
            if effect() {
                passed.append("\(surface): \(name)")
                Log.line("SWEEP OK \(surface): \(name) [keys: \(before)]")
                await app.sleep(0.25)
                return true
            }
        }
        broken.append("\(surface): \(name) [keys: \(before)]")
        Log.line("SWEEP BROKEN \(surface): \(name) [keys: \(before)]")
        return false
    }

    /// Brings the window to the front with the keys, and throws when it does not get them: a key sent to the wrong
    /// window says nothing of the key. A sheet comes with its window, so only the app comes to the front for it.
    func makeKey(_ window: NSWindow, _ name: String) async throws {
        for _ in 0..<40 where !window.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            if window.sheetParent == nil { window.makeKeyAndOrderFront(nil) }
            await app.sleep(0.15)
        }
        guard window.isKeyWindow else { throw DriverFailure("\(name) did not get the keys") }
    }

    /// Logs a check that needs no key: the effect holds or it does not.
    func expect(_ surface: String, _ name: String, _ holds: Bool) {
        if holds {
            passed.append("\(surface): \(name)")
            Log.line("SWEEP OK \(surface): \(name) [keys: \(holder)]")
        } else {
            broken.append("\(surface): \(name) [keys: \(holder)]")
            Log.line("SWEEP BROKEN \(surface): \(name) [keys: \(holder)]")
        }
    }

    func note(_ text: String) { Log.line("SWEEP NOTE \(text)") }

    /// A copy of the items on your pasteboard, for `restorePasteboard`.
    func savePasteboard() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    /// Puts back the items that `savePasteboard` copied.
    func restorePasteboard(_ items: [NSPasteboardItem]) {
        NSPasteboard.general.clearContents()
        if !items.isEmpty && !NSPasteboard.general.writeObjects(items) {
            note("your pasteboard could not be put back")
        }
    }

    /// Logs the counts and each broken key. A broken key fails the scenario.
    func summary() throws {
        Log.line("SWEEP SUMMARY \(passed.count) ok, \(broken.count) broken")
        for line in broken { Log.line("SWEEP BROKEN-LIST \(line)") }
        if !broken.isEmpty { throw DriverFailure("\(broken.count) keys are broken: \(broken.joined(separator: "; "))") }
    }
}

@MainActor
extension Scenarios {
    static func keySweep(_ app: DriverApp) async throws {
        do { try await keySweepSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func keySweepSteps(_ app: DriverApp) async throws {
        let (rig, environment, _) = try shotRig(app)
        let (repo, _) = try widgetsRepo(rig, onGitHub: false)
        let plot = try rig.newPlot("Loam v1 build")
        try rig.loam(["repo", "add", plot, repo.path], extra: environment)
        let draft = rig.root.appendingPathComponent("draft.json")
        try #"""
        {"type": "result", "subtype": "success", "is_error": false, "result": "",
         "structured_output": {
          "goal": "A search for a link label finds its plot.",
          "checks": [{"name": "Search tests", "command": "go test ./search/..."}],
          "assumptions": ["A label match counts for less than a title match."],
          "plan": ["Score the label of a link."], "size": "About 80 lines."}}
        """#.write(to: draft, atomically: true, encoding: .utf8)
        try printDraft(rig, draft)
        // A map with tickets, for the intake and for three drafts on the desk.
        let map = rig.root.appendingPathComponent("maps/build")
        try FileManager.default.createDirectory(at: map.appendingPathComponent("issues"), withIntermediateDirectories: true)
        try "# Build\n".write(to: map.appendingPathComponent("map.md"), atomically: true, encoding: .utf8)
        for n in 1...5 {
            try "Status: open\n\n# Ticket \(n)\n\nThe text of ticket \(n).\n"
                .write(to: map.appendingPathComponent("issues/\(n)-ticket.md"), atomically: true, encoding: .utf8)
        }
        try rig.loam(["link", "add", plot, "Build map", map.appendingPathComponent("map.md").path])
        for n in 1...3 {
            try rig.loam(["run", "shape", plot, "--title", "Draft \(n)", "--ticket",
                          map.appendingPathComponent("issues/\(n)-ticket.md").path, "--json"], extra: environment)
        }

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        frameLikeTheDesign(host.window)
        host.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let model = host.model
        let sweep = try KeySweep(app)
        try await app.waitUntil("the plot loads") { model.plots.count == 1 && model.workspace.activePlotID == plot }
        try await sweep.makeKey(host.window, "the main window")
        let space = Space.plot(plot)
        func panes() -> Int { model.workspace.paneCount(of: space) }
        func tabs() -> Int { model.workspace.tabs(of: space).count }
        func tabIndex() -> Int? { model.workspace.selectedTabIndex(of: space) }
        sweep.note("start: page \(String(describing: model.page)), keys \(sweep.holder)")

        // MARK: Window keys from a terminal pane.
        let s = "Terminal pane"
        await sweep.check(s, "⌘⌥T New Shell Tab", "t", [.command, .option]) { panes() == 1 }
        await app.sleep(0.5)
        // A terminal pane has no Undo, Redo or Cut, so the items are off there, and ⌘Z goes on to the terminal.
        let edit = NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
        edit?.update()
        let editOn = ["Undo", "Redo", "Cut"].filter { edit?.item(withTitle: $0)?.isEnabled ?? false }
        sweep.expect(s, "Undo, Redo and Cut are off", host.window.firstResponder is TerminalSurfaceView && editOn.isEmpty)
        if !editOn.isEmpty { sweep.note("on in a terminal pane: \(editOn)") }
        await sweep.check(s, "⌘T New Tab", "t", .command) { tabs() == 2 }
        await sweep.check(s, "⌘D Split Right", "d", .command) { panes() == 3 }
        let focused = model.workspace.focusedPane
        await sweep.check(s, "⌘[ Previous Split", "[", .command) { model.workspace.focusedPane != focused }
        await sweep.check(s, "⌘] Next Split", "]", .command) { model.workspace.focusedPane == focused }
        await sweep.check(s, "⌘⇧D Split Down", "d", [.command, .shift]) { panes() == 4 }
        await sweep.check(s, "⌘1 Tab 1", "1", .command) { tabIndex() == 0 }
        await sweep.check(s, "⌘⇧] Next Tab", "]", [.command, .shift]) { tabIndex() == 1 }
        await sweep.check(s, "⌘⇧[ Previous Tab", "[", [.command, .shift]) { tabIndex() == 0 }
        await sweep.check(s, "⌘9 Last Tab", "9", .command) { tabIndex() == 1 }
        let sidebar = model.sidebarCollapsed
        await sweep.check(s, "⌘B Toggle Sidebar", "b", .command) { model.sidebarCollapsed != sidebar }
        await sweep.check(s, "⌘B Toggle Sidebar back", "b", .command) { model.sidebarCollapsed == sidebar }
        let panel = model.panel.visible
        await sweep.check(s, "⌘I Plot Panel", "i", .command) { model.panel.visible != panel }
        await sweep.check(s, "⌘I Plot Panel back", "i", .command) { model.panel.visible == panel }
        await sweep.check(s, "⌘P Quick Switcher", "p", .command) { model.switcher.isOpen }
        let selection = model.switcher.selection
        sweep.note("switcher results: \(model.switcher.results.count)")
        await sweep.check("Switcher", "↓ moves the selection", "\u{F701}") { model.switcher.selection != selection }
        await sweep.check("Switcher", "↑ moves the selection back", "\u{F700}") { model.switcher.selection == selection }
        await sweep.check("Switcher", "Esc closes", "\u{1B}") { !model.switcher.isOpen }
        await sweep.check(s, "⌘⇧P Quick Switcher Actions", "p", [.command, .shift]) { model.switcher.isOpen }
        await sweep.type("split right")
        let before = panes()
        await sweep.check("Switcher", "↩ runs the selected action", "\r") { !model.switcher.isOpen && panes() == before + 1 }
        await sweep.check(s, "⌘J Actions", "j", .command) { app.exists("actions-menu") }
        await sweep.check("Actions menu", "Esc closes", "\u{1B}") { !app.exists("actions-menu") }
        await sweep.check(s, "⌘J Actions again", "j", .command) { app.exists("actions-menu") }
        await sweep.type("split down")
        let before2 = panes()
        await sweep.check("Actions menu", "↩ runs the selected action", "\r") { !app.exists("actions-menu") && panes() == before2 + 1 }
        let paneCount = panes()
        await sweep.check(s, "⌘W Close pane", "w", .command, timeout: 4) { panes() == paneCount - 1 }
        await sweep.check(s, "⌃0 Home", "0", .control) { model.workspace.activeSpace == .home }
        await sweep.check("Home", "⌃1 Plot 1", "1", .control) { model.workspace.activePlotID == plot }
        await app.sleep(0.5); sweep.note("after ⌃1: keys \(sweep.holder)")
        if sweep.holder.hasPrefix("SessionEndedBar"), let pane = model.workspace.focusedPane {
            let launch = model.workspace.launch(of: pane)
            await sweep.check("Session ended bar", "N New session", "n", timeout: 3) { model.workspace.launch(of: pane) != launch }
            await app.sleep(0.5)
        } else {
            sweep.note("no Session ended bar has the keys: \(sweep.holder)")
        }

        // ⌘, opens Settings, and ⌘W there closes Settings, not a pane.
        func settingsWindow() -> NSWindow? {
            NSApp.windows.first { $0 !== host.window && $0.isVisible && $0.contentViewController is NSTabViewController }
        }
        await sweep.check(s, "⌘, Settings", ",", .command) { settingsWindow() != nil }
        if let settings = settingsWindow() {
            try await sweep.makeKey(settings, "Settings")
            let count = panes()
            await sweep.check("Settings window", "⌘W closes Settings and no pane", "w", .command, timeout: 3) {
                settingsWindow() == nil && panes() == count
            }
            if panes() != count { sweep.note("⌘W in Settings closed a pane: \(count) -> \(panes())") }
            settingsWindow()?.close()
            host.window.makeKeyAndOrderFront(nil)
            await app.sleep(0.3)
        }
        // A sheet over Settings has the keys: ⌘W closes nothing, not Settings and not a pane.
        await sweep.check(s, "⌘, Settings again", ",", .command) { settingsWindow() != nil }
        if let settings = settingsWindow() {
            let alert = NSAlert()
            alert.messageText = "A sheet over Settings"
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: settings) { _ in }
            try await sweep.makeKey(alert.window, "the sheet over Settings")
            let count = panes()
            sweep.post("w", .command)
            await app.sleep(1)
            sweep.expect("Sheet over Settings", "⌘W closes no pane and leaves Settings open",
                         panes() == count && settingsWindow() != nil)
            settings.endSheet(alert.window)
            // A sheet of Loam on the main window does not turn Close off in Settings.
            _ = model.openNewWorktree(plot: plot)
            try await app.waitUntil("the New worktree sheet shows") { app.exists("new-worktree-sheet") }
            try await sweep.makeKey(settings, "Settings")
            await sweep.check("Settings over a Loam sheet", "⌘W closes Settings", "w", .command, timeout: 3) {
                settingsWindow() == nil && panes() == count
            }
            settingsWindow()?.close()
            host.window.makeKeyAndOrderFront(nil)
            await app.sleep(0.3)
            await sweep.check("New worktree sheet", "Esc closes", "\u{1B}") { !app.exists("new-worktree-sheet") }
        }

        // ⌘N asks for a plot name in a sheet, and Esc cancels it.
        await sweep.check(s, "⌘N New Plot", "n", .command) { host.window.attachedSheet != nil }
        if host.window.attachedSheet != nil {
            await sweep.check("New Plot sheet", "Esc cancels", "\u{1B}") { host.window.attachedSheet == nil }
            host.window.attachedSheet.map { host.window.endSheet($0) }
        }
        await app.sleep(0.5)
        // A control: an alert with a Cancel button and no text field.
        let control = NSAlert()
        control.messageText = "Control"
        control.addButton(withTitle: "OK")
        control.addButton(withTitle: "Cancel")
        control.beginSheetModal(for: host.window) { _ in }
        try await app.waitUntil("the control alert shows") { host.window.attachedSheet != nil }
        await app.sleep(0.3)
        await sweep.check("Control alert (no text field)", "Esc cancels", "\u{1B}") { host.window.attachedSheet == nil }
        host.window.attachedSheet.map { host.window.endSheet($0) }
        await app.sleep(0.3)

        // MARK: Today.
        try await sweep.click("sidebar-today")
        try await app.waitUntil("Today shows") { model.page == .today }
        sweep.note("Today: keys \(sweep.holder)")
        let t = "Today"
        await sweep.check(t, "⌘P Quick Switcher", "p", .command) { model.switcher.isOpen }
        await sweep.check("Switcher over Today", "Esc closes", "\u{1B}") { !model.switcher.isOpen }
        await sweep.check(t, "⌘J Actions", "j", .command) { app.exists("actions-menu") }
        await sweep.check("Actions menu over Today", "Esc closes", "\u{1B}") { !app.exists("actions-menu") }
        let sidebar2 = model.sidebarCollapsed
        await sweep.check(t, "⌘B Toggle Sidebar", "b", .command) { model.sidebarCollapsed != sidebar2 }
        await sweep.check(t, "⌘B Toggle Sidebar back", "b", .command) { model.sidebarCollapsed == sidebar2 }
        await sweep.check(t, "⌘R Start a run (opens the intake)", "r", .command) {
            if case .intake = model.page { true } else { false }
        }
        if case .intake = model.page {
            try await sweep.click("sidebar-today")
            try await app.waitUntil("Today shows again") { model.page == .today }
        }
        try await app.waitUntil("the drafts are in") {
            model.deskQueue.count == 3 && model.runs.allSatisfy { $0.shape?.isDrafted == true }
        }
        await sweep.check(t, "⌘↩ Open the desk", "\r", .command) { model.page == .desk }
        if model.page != .desk { await model.openDesk() }

        // MARK: The desk, Shape.
        try await app.waitUntil("the desk shows a draft") { app.exists("desk-shape") && app.exists("desk-approve") }
        await app.sleep(0.5)
        let d = "Desk Shape"
        sweep.note("Desk: keys \(sweep.holder)")
        let first = model.desk.runID
        await sweep.check(d, "J Next", "j") { model.desk.runID != first }
        await sweep.check(d, "K Previous", "k") { model.desk.runID == first }
        await sweep.check(d, "Esc Leave the desk", "\u{1B}") { model.page == .today }
        if model.page != .desk { await model.openDesk() }
        try await app.waitUntil("the desk shows a draft again") { app.exists("desk-approve") }
        await app.sleep(0.5)
        await sweep.check(d, "C Ask Claude to change it", "c") { app.exists("desk-change-field") }
        if app.exists("desk-change-field") {
            try await app.waitUntil("the change field has the keys", timeout: 3) { app.fieldWithTheKeys() == "Change for Claude" }
            await sweep.type("hello")
            func changeText() -> String? { (host.window.firstResponder as? NSTextView)?.string }
            sweep.note("typed into the change field: \(changeText() ?? "nil")")
            await sweep.check("Text field", "⌘A Select All", "a", .command) {
                (app.window.firstResponder as? NSTextView)?.selectedRange().length == 5
            }
            // ⌘C and ⌘X in a text view write to your pasteboard, so the sweep puts its items back.
            let saved = sweep.savePasteboard()
            defer { sweep.restorePasteboard(saved) }
            // The count of the pasteboard shows the copy.
            let copies = NSPasteboard.general.changeCount
            await sweep.check("Text field", "⌘C Copy", "c", .command) {
                NSPasteboard.general.changeCount != copies && NSPasteboard.general.string(forType: .string) == "hello"
            }
            await sweep.check("Text field", "⌘X Cut", "x", .command) { changeText() == "" }
            if changeText() != "" { (app.window.firstResponder as? NSTextView)?.cut(nil) }
            await sweep.check("Text field", "⌘V Paste", "v", .command) { changeText() == "hello" }
            await sweep.check("Text field", "⌘Z Undo", "z", .command) { changeText() != "hello" }
            // Redo needs an Undo to redo.
            let undone = changeText() != "hello"
            await sweep.check("Text field", "⌘⇧Z Redo", "z", [.command, .shift]) { undone && changeText() == "hello" }
            await sweep.check(d, "Esc closes the change field", "\u{1B}") { !app.exists("desk-change-field") }
            sweep.note("after Esc in the change field: page \(String(describing: model.page)), keys \(sweep.holder)")
            if model.page != .desk { await model.openDesk() }
        }
        try await app.waitUntil("the desk shows a draft again") { app.exists("desk-approve") }
        await app.sleep(0.5)
        let toCancel = model.desk.runID
        await sweep.check(d, "N Not now", "n", timeout: 4) { model.runs.first { $0.id == toCancel }?.state != .shaping }
        try await app.waitUntil("the next draft shows") { model.desk.runID != toCancel && app.exists("desk-approve") }
        await app.sleep(0.5)

        // A after a click in the goal field and Esc out of it.
        try await sweep.click("desk-goal")
        sweep.note("after a click on the goal: keys \(sweep.holder)")
        sweep.post("\u{1B}")
        await app.sleep(0.4)
        sweep.note("after Esc in the goal: keys \(sweep.holder)")
        let afterField = model.desk.runID
        await sweep.check(d, "A Approve after Esc leaves the goal field", "a", timeout: 4) {
            model.runs.first { $0.id == afterField }?.state != .shaping
        }
        if model.runs.first(where: { $0.id == afterField })?.state == .shaping {
            sweep.note("goal after the A: \(AccessibilityProbe.shared.node("desk-goal")?.value ?? "nil")")
            // A click on an empty part of the desk, then A again.
            try await sweep.click("desk-item-title")
            await sweep.check(d, "A Approve after a click on the title", "a", timeout: 4) {
                model.runs.first { $0.id == afterField }?.state != .shaping
            }
            if model.runs.first(where: { $0.id == afterField })?.state == .shaping { await model.approveDeskRun() }
        }
        try await app.waitUntil("the last draft shows") { app.exists("desk-approve") && model.desk.runID != afterField }
        await app.sleep(0.5)
        let last = model.desk.runID
        await sweep.check(d, "A Approve and next", "a", timeout: 4) { model.runs.first { $0.id == last }?.state != .shaping }

        // MARK: Intake.
        try await sweep.click("sidebar-intake")
        try await app.waitUntil("the intake shows") { model.page == .intake(plot) && app.exists("intake-detail-title") }
        await app.sleep(0.5)
        sweep.note("Intake: keys \(sweep.holder)")
        let i = "Intake"
        func detail() -> String? { app.text(of: "intake-detail-title") }
        let row0 = detail()
        await sweep.check(i, "↓ next row", "\u{F701}") { detail() != row0 }
        let row1 = detail()
        await sweep.check(i, "J next row", "j") { detail() != row1 }
        await sweep.check(i, "K previous row", "k") { detail() == row1 }
        await sweep.check(i, "↑ previous row", "\u{F700}") { detail() == row0 }
        // A click on a row with no run, then X, X, X and ⌘↩.
        try await sweep.click("intake-row-map 4")
        try await app.waitUntil("the detail shows ticket 4") { detail() == "Ticket 4" }
        sweep.note("after a click on a row: keys \(sweep.holder)")
        func batch() -> String? { app.text(of: "intake-batch-start") }
        await sweep.check(i, "X checks the row", "x") { batch() == "Shape 1 run" }
        await sweep.check(i, "X unchecks the row", "x") { batch() == nil }
        await sweep.check(i, "X checks the row again", "x") { batch() == "Shape 1 run" }
        let runCount = model.runs.count
        await sweep.check(i, "⌘↩ Shape 1 run", "\r", .command, timeout: 5) { model.runs.count > runCount }
        // The row with a run goes to the end of the list, so the keys go up first.
        let clicked = detail()
        await sweep.check(i, "↑ after ⌘↩", "\u{F700}") { detail() != clicked }
        await sweep.check(i, "↓ after ⌘↩", "\u{F701}") { detail() == clicked }
        await sweep.check(i, "K after ⌘↩", "k") { detail() != clicked }
        await sweep.check(i, "J after ⌘↩", "j") { detail() == clicked }
        if app.exists("intake-chore") {
            try await sweep.click("intake-chore")
            try? await app.waitUntil("the start sheet opens", timeout: 3) { app.exists("intake-start-sheet") }
            if app.exists("intake-start-sheet") {
                await sweep.check("Intake start sheet", "Esc cancels", "\u{1B}") { !app.exists("intake-start-sheet") }
            } else {
                sweep.note("the start sheet did not open")
            }
        }

        // MARK: Sheets of Loam.
        if model.page != nil {
            await sweep.check(i, "⌃1 Plot 1 leaves the page", "1", .control) { model.page == nil }
            if model.page != nil { model.closePage() }
        }
        await app.sleep(0.5)
        _ = model.openNewWorktree(plot: plot)
        try await app.waitUntil("the New worktree sheet shows") { app.exists("new-worktree-sheet") }
        await app.sleep(0.5)
        sweep.note("New worktree: keys \(sweep.holder)")
        let w = "New worktree sheet"
        await sweep.type("sweep-branch")
        let field = app.fieldWithTheKeys()
        await sweep.check(w, "Tab moves to the next field", "\t") { app.fieldWithTheKeys() != field }
        await sweep.check(w, "⇧Tab moves back", "\t", .shift) { app.fieldWithTheKeys() == field }
        let tabsUnder = tabs()
        sweep.post("t", .command)
        await app.sleep(1)
        sweep.expect(w, "⌘T is off under the sheet", tabs() == tabsUnder)
        await sweep.check(w, "Esc closes", "\u{1B}") { !app.exists("new-worktree-sheet") }

        // MARK: The plot panel.
        if !model.panel.visible { sweep.post("i", .command) }
        try await app.waitUntil("the panel shows") { model.panel.visible }
        await app.sleep(0.6)
        sweep.note("Plot panel: keys \(sweep.holder)")
        let pp = "Plot panel"
        try await sweep.click("panel-what")
        sweep.note("after a click on What: keys \(sweep.holder)")
        await sweep.type(" More")
        await sweep.check(pp, "⌘↩ saves What", "\r", .command, timeout: 4) { model.panel.plot?.what.hasSuffix("More") == true }
        try await sweep.click("panel-why")
        let why = app.fieldWithTheKeys()
        sweep.note("after a click on Why: keys \(sweep.holder)")
        await sweep.check(pp, "Esc ends editing Why", "\u{1B}") {
            app.fieldWithTheKeys() != why || why == nil && !(host.window.firstResponder is NSTextView)
        }
        try await sweep.click("panel-add-link-open")
        try? await app.waitUntil("the add link row", timeout: 3) { app.exists("panel-new-link-label") }
        sweep.note("add link row: keys \(sweep.holder)")
        await sweep.check(pp, "Esc closes the add link row", "\u{1B}") { !app.exists("panel-new-link-label") }
        try sweep.summary()
    }
}
