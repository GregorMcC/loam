import AppKit
import ApplicationServices
import LoamKit

/// Driver scenarios for the plot panel (tickets 35 and 36, run by the phase 5 gate).
/// They drive the real window through the accessibility tree and use a temp store:
/// `LOAM_HOME`, a fake `HOME` with an Obsidian vault list, a temp `state.json`,
/// and a fake `LOAM_OPEN` that logs its arguments. They never touch `~/.loam`.
/// A change "by Claude" comes from `loam mcp` with a session ID, as the core records one.

/// The temp store and the helpers to run `loam` against it.
@MainActor
struct PanelRig {
    let root: URL
    let loamHome: URL
    let fakeHome: URL
    let vault: URL
    let openLog: URL
    let stateFile: AppStateFile
    let binary: URL
    let environment: [String: String]

    init(outFolder: String) throws {
        try self.init(root: URL(fileURLWithPath: outFolder).appendingPathComponent("rig"), fresh: true)
    }

    /// A rig in `root`. `fresh` removes what is there first. Without it, a second app run finds the
    /// store and the `state.json` of the first run (the restore scenarios).
    init(root: URL, fresh: Bool) throws {
        let fm = FileManager.default
        self.root = root
        if fresh { try? fm.removeItem(at: root) }
        loamHome = root.appendingPathComponent("loam-home")
        fakeHome = root.appendingPathComponent("home")
        vault = fakeHome.appendingPathComponent("vault")
        openLog = root.appendingPathComponent("open.log")
        stateFile = AppStateFile(url: root.appendingPathComponent("state/state.json"))
        let override = ProcessInfo.processInfo.environment["LOAM_DRIVER_LOAM"]
        binary = override.map { URL(fileURLWithPath: $0) } ?? LoamClient.defaultBinary

        try fm.createDirectory(at: vault.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try "A note.\n".write(to: vault.appendingPathComponent("Notes/Note.md"), atomically: true, encoding: .utf8)
        let obsidian = fakeHome.appendingPathComponent("Library/Application Support/obsidian")
        try fm.createDirectory(at: obsidian, withIntermediateDirectories: true)
        let config = #"{"vaults":{"driver":{"path":"\#(vault.path)"}}}"#
        try config.write(to: obsidian.appendingPathComponent("obsidian.json"), atomically: true, encoding: .utf8)

        // The fake open: logs its arguments and succeeds. `open -Ra Obsidian` succeeds too.
        let fake = root.appendingPathComponent("fake-open")
        try "#!/bin/sh\necho \"$@\" >> '\(openLog.path)'\nexit 0\n".write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        environment = [
            "LOAM_HOME": loamHome.path,
            "HOME": fakeHome.path,
            "LOAM_OPEN": fake.path,
            "LOAM_APP_STATE_DIR": root.appendingPathComponent("state").path,
        ]
    }

    var client: LoamClient { LoamClient(binary: binary, environment: environment) }

    var openCalls: [String] {
        ((try? String(contentsOf: openLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Runs `loam` with the temp store and returns stdout. Throws on a non-zero exit.
    @discardableResult
    func loam(_ args: [String], extra: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { $1 }.merging(extra) { $1 }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw DriverFailure("loam \(args.joined(separator: " ")) exited \(process.terminationStatus): \(text)")
        }
        return text
    }

    func json(_ args: [String]) throws -> [String: Any] {
        let text = try loam(args + ["--json"])
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw DriverFailure("loam \(args.joined(separator: " ")) did not print an object")
        }
        return object
    }

    func newPlot(_ name: String) throws -> String {
        guard let id = try json(["new", name])["id"] as? String else { throw DriverFailure("no plot ID") }
        return id
    }

    func show(_ plot: String) throws -> [String: Any] { try json(["show", plot]) }

    func changes(_ plot: String) throws -> [[String: Any]] {
        try json(["changes", plot])["changes"] as? [[String: Any]] ?? []
    }

    func lastChangeID(_ plot: String) throws -> Int {
        try changes(plot).compactMap { $0["id"] as? Int }.max() ?? 0
    }

    /// A change by Claude, the way the core records one: the MCP server with a
    /// session ID reads the plot, then writes where-it-stands.
    func claudeSetsWhere(_ plot: String, _ text: String, session: String = "bbbbbbbb-1111-4222-8333-444444444444") async throws {
        let before = try lastChangeID(plot)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["mcp"]
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { $1 }
            .merging(["CLAUDE_CODE_SESSION_ID": session]) { $1 }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()

        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try stdin.fileHandleForWriting.write(contentsOf: data)
        }
        func call(_ id: Int, _ tool: String, _ arguments: [String: Any]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
        }
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [String: Any](),
            "clientInfo": ["name": "loam-driver", "version": "1"]]])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try send(call(2, "get_plot", ["plot": plot]))
        try await Task.sleep(for: .milliseconds(400))
        try send(call(3, "set_where_it_stands", ["plot": plot, "text": text]))
        try await Task.sleep(for: .milliseconds(400))
        try stdin.fileHandleForWriting.close()
        for _ in 0..<100 where process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        if process.isRunning { process.terminate() }
        // The reply can be lost when stdin closes, so check the store.
        guard try lastChangeID(plot) > before else {
            let output = String(decoding: stdout.fileHandleForReading.availableData, as: UTF8.self)
            throw DriverFailure("the MCP write did not record a change: \(output)")
        }
    }
}

// MARK: Accessibility

/// Reads and drives the app through the macOS accessibility API, the way an
/// outside tool does. SwiftUI builds its accessibility tree only after a
/// client asks, so `start` asks once. A call about the own process runs on the
/// calling thread, so every call here runs on the main thread.
@MainActor
final class AccessibilityProbe {
    static let shared = AccessibilityProbe()

    struct Node {
        var value = ""
        var title = ""
        var description = ""
        /// On screen, in points, top-left origin.
        var frame: CGRect?
        var text: String { [value, title, description].first { !$0.isEmpty } ?? "" }
    }

    private var nodes: [String: Node] = [:]
    private var scanned = Date.distantPast
    private var started = false
    private let pid = getpid()

    func start() {
        guard !started else { return }
        started = true
        let pid = self.pid
        // The first request switches the tree on. Ask from another thread.
        let thread = Thread {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXChildrenAttribute as CFString, &value)
            Log.line("accessibility switched on: status \(status.rawValue), trusted \(AXIsProcessTrusted())")
        }
        thread.start()
    }

    func node(_ id: String) -> Node? {
        if Date().timeIntervalSince(scanned) > 0.15 {
            nodes = scan()
            scanned = Date()
        }
        return nodes[id]
    }

    var ids: [String] { scan().keys.sorted() }

    /// The sidebar row that holds the row `id` in the tree (ticket 71): the nearest row above it that
    /// starts further left, so it sits one or more levels out. Nil when there is none. The rows are
    /// the elements named `plot-`, `main-checkout-`, `repo-checkout-`, `worktree-`, `tab-row-` and `pane-row-`.
    func treeParent(of id: String) -> String? {
        guard let child = node(id)?.frame else { return nil }
        let prefixes = ["plot-", "main-checkout-", "repo-checkout-", "worktree-", "tab-row-", "pane-row-"]
        let rows = nodes.compactMap { key, node -> (String, CGRect)? in
            guard prefixes.contains(where: key.hasPrefix), !key.hasPrefix("plot-new-changes-"),
                  let frame = node.frame, frame.width > 0 else { return nil }
            return (key, frame)
        }
        return rows.filter { $0.1.minY < child.minY - 1 && $0.1.minX < child.minX - 1 }
            .max { $0.1.minY < $1.1.minY }?.0
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        // The type checks above make the casts safe.
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// The tree under the plot panel, one line per element, for a failed run.
    func dump() -> [String] {
        var lines: [String] = []
        func go(_ element: AXUIElement, depth: Int) {
            guard depth < 40 else { return }
            let id = string(element, "AXIdentifier")
            let text = [string(element, kAXTitleAttribute), string(element, kAXValueAttribute), string(element, kAXDescriptionAttribute)]
                .filter { !$0.isEmpty }.joined(separator: " | ")
            if depth > 3, !string(element, kAXRoleAttribute).hasPrefix("AXMenu") { lines.append(String(repeating: " ", count: depth) + string(element, kAXRoleAttribute) + " id=" + id + " " + String(text.prefix(60))) }
            for child in children(element) { go(child, depth: depth + 1) }
        }
        go(AXUIElementCreateApplication(pid), depth: 0)
        return lines
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func walk(_ element: AXUIElement, depth: Int, _ visit: (AXUIElement, String) -> Bool) -> Bool {
        guard depth < 40 else { return false }
        if visit(element, string(element, "AXIdentifier")) { return true }
        for child in children(element) where walk(child, depth: depth + 1, visit) { return true }
        return false
    }

    private func scan() -> [String: Node] {
        var found: [String: Node] = [:]
        _ = walk(AXUIElementCreateApplication(pid), depth: 0) { element, id in
            if !id.isEmpty {
                found[id] = Node(
                    value: string(element, kAXValueAttribute), title: string(element, kAXTitleAttribute),
                    description: string(element, kAXDescriptionAttribute), frame: frame(element))
            }
            return false
        }
        return found
    }

    /// Runs an action on the element with this identifier. Returns false when no element took it.
    private func perform(_ id: String, _ body: (AXUIElement) -> Bool) -> Bool {
        scanned = .distantPast
        return walk(AXUIElementCreateApplication(pid), depth: 0) { element, found in found == id && body(element) }
    }

    func press(_ id: String) -> Bool {
        perform(id) { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success }
    }

    /// Selects the sidebar row `id`, as a click does: the row takes the press action (ticket 86 draws
    /// its own selection, so the list has none).
    func selectRow(_ id: String) -> Bool { press(id) }

    /// Opens or closes the list row that holds the element, as its disclosure arrow does.
    func discloseRow(_ id: String, open: Bool) -> Bool {
        perform(id) { element in
            let value = open ? kCFBooleanTrue : kCFBooleanFalse
            return row(holding: element).map { AXUIElementSetAttributeValue($0, kAXDisclosingAttribute as CFString, value!) == .success } ?? false
        }
    }

    /// The nearest `AXRow` ancestor of the element.
    private func row(holding element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let row = current else { return nil }
            if string(row, kAXRoleAttribute) == kAXRowRole as String { return row }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(row, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = (parent as! AXUIElement)  // The type check above makes the cast safe.
        }
        return nil
    }

    func focus(_ id: String) -> Bool {
        perform(id) { AXUIElementSetAttributeValue($0, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success }
    }

    func setValue(_ id: String, _ text: String) -> Bool {
        perform(id) { AXUIElementSetAttributeValue($0, kAXValueAttribute as CFString, text as CFString) == .success }
    }

    /// True when the element with this identifier has the keyboard focus.
    func isFocused(_ id: String) -> Bool { flag(id, kAXFocusedAttribute) }

    /// True when the element with this identifier is enabled.
    func isEnabled(_ id: String) -> Bool { flag(id, kAXEnabledAttribute) }

    private func flag(_ id: String, _ attribute: String) -> Bool {
        var on = false
        _ = perform(id) { element in
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success {
                on = (value as? Bool) ?? false
            }
            return true
        }
        return on
    }

    /// Runs the named custom action (`accessibilityActions` in SwiftUI) of the element with this
    /// identifier. AppKit lists a custom action as "Name:<name>" and more lines.
    func performAction(_ id: String, named name: String) -> Bool {
        perform(id) { element in
            var names: CFArray?
            guard AXUIElementCopyActionNames(element, &names) == .success,
                  let action = (names as? [String])?.first(where: { $0 == name || $0.hasPrefix("Name:\(name)\n") })
            else { return false }
            return AXUIElementPerformAction(element, action as CFString) == .success
        }
    }
}

@MainActor
extension DriverApp {
    func exists(_ id: String) -> Bool { AccessibilityProbe.shared.node(id) != nil }

    /// Runs a named custom action, such as a row action that the hover menu also holds.
    func perform(_ action: String, on id: String) throws {
        guard AccessibilityProbe.shared.performAction(id, named: action) else {
            throw DriverFailure("no element \(id) took the action \(action)")
        }
        Log.line("action \(action) on \(id)")
    }

    /// The text of an element: its value, else its title or description.
    func text(of id: String) -> String? { AccessibilityProbe.shared.node(id)?.text }

    /// The sidebar row that holds the row `id` in the tree (ticket 71).
    func treeParent(of id: String) -> String? { AccessibilityProbe.shared.treeParent(of: id) }

    /// Selects the sidebar row that holds the element `id`, through the accessibility API.
    func selectRow(_ id: String) throws {
        guard AccessibilityProbe.shared.selectRow(id) else { throw DriverFailure("no list row holds \(id)") }
        Log.line("select row \(id)")
    }

    /// Clicks a button with the accessibility press action.
    func click(_ id: String) throws {
        guard AccessibilityProbe.shared.press(id) else { throw DriverFailure("no element \(id) took the press") }
        Log.line("click \(id)")
    }

    /// Replaces the text of a field.
    func fill(_ id: String, with text: String) throws {
        // Focus the field and type into its editor, so SwiftUI sees an edit.
        if AccessibilityProbe.shared.focus(id), let editor = window.firstResponder as? NSTextView {
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            Log.line("fill \(id)")
            return
        }
        guard AccessibilityProbe.shared.setValue(id, text) else { throw DriverFailure("no element \(id) took the text") }
        Log.line("fill \(id)")
    }

    /// Logs the accessibility identifiers, for a failed run.
    func dumpAccessibility() {
        for line in AccessibilityProbe.shared.dump() { Log.line("AX " + line) }
    }

    /// Presses a menu key equivalent such as command-I through the main menu.
    func pressMenuKey(_ letter: Character, flags: NSEvent.ModifierFlags = .command) throws {
        let codes: [Character: UInt16] = ["i": 34, "p": 35, "w": 13, "t": 17, "1": 18, "2": 19, "b": 11, "l": 37, ",": 43, "j": 38]
        guard let code = codes[letter],
              let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: String(letter), charactersIgnoringModifiers: String(letter),
                isARepeat: false, keyCode: code)
        else { throw DriverFailure("no key event for \(letter)") }
        guard NSApp.mainMenu?.performKeyEquivalent(with: event) == true else {
            throw DriverFailure("the main menu took no key \(letter)")
        }
    }

    /// Waits for the panel to load the active plot.
    func openPanel(_ host: AppHost) async throws {
        try await waitUntil("a plot is active") { host.model.workspace.activePlotID != nil }
        try pressMenuKey("i")
        do {
            try await waitUntil("the plot panel shows", timeout: 5) { self.exists("plot-panel") && self.exists("panel-whereItStands") }
        } catch {
            dumpAccessibility()
            throw error
        }
    }
}

// MARK: Scenarios

@MainActor
extension Scenarios {
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    private static func string(_ object: [String: Any], _ key: String) -> String { object[key] as? String ?? "" }

    /// Ticket 35: edit the brief, add a link, open a vault link, meet a missing link and an edit clash.
    static func panelEdit(_ app: DriverApp) async throws {
        do { try await panelEditSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func panelEditSteps(_ app: DriverApp) async throws {
        let rig = try PanelRig(outFolder: app.outFolder)
        let plot = try rig.newPlot("Panel plot")
        try rig.loam(["set", plot, "where-it-stands", "start"])
        let note = rig.vault.appendingPathComponent("Notes/Note.md").path
        try rig.loam(["link", "add", plot, "Vault note", note])
        try rig.loam(["link", "add", plot, "Gone note", "/nonexistent-loam-driver/Gone.md"])
        let links = try rig.show(plot)["links"] as? [[String: Any]] ?? []
        guard let vaultID = links.first(where: { string($0, "label") == "Vault note" }).map({ string($0, "id") }),
              let goneID = links.first(where: { string($0, "label") == "Gone note" }).map({ string($0, "id") })
        else { throw DriverFailure("the seed links are missing") }
        try check(links.first(where: { string($0, "id") == vaultID }).map { string($0, "kind") } == "vault", "the note is not a vault link")

        let host = try await app.launchApp(client: rig.client, state: rig.stateFile)
        try await app.openPanel(host)
        app.screenshot("panel-open")

        // Edit where-it-stands and save. The change has the app actor.
        try app.fill("panel-whereItStands", with: "typed in the panel")
        try await app.waitUntil("the Save button") { app.exists("panel-save-whereItStands") }
        try app.click("panel-save-whereItStands")
        try await app.waitUntil("the stored where-it-stands") {
            ((try? rig.show(plot)) .map { string($0, "where_it_stands") }) == "typed in the panel"
        }
        let lastActor = try rig.changes(plot).last.flatMap { $0["actor"] as? [String: Any] }.map { string($0, "kind") }
        try check(lastActor == "app", "the last change has actor \(lastActor ?? "none"), not app")

        // Ticket 72: Return in a brief field adds a new line. It does not save.
        try app.fill("panel-whereItStands", with: "line one")
        app.press(.returnKey)
        try app.type("two")
        try await app.waitUntil("the second line in the field") { app.text(of: "panel-whereItStands") == "line one\ntwo" }
        await app.sleep(0.5)
        try check(string(try rig.show(plot), "where_it_stands") == "typed in the panel", "Return saved the field")
        try await app.waitUntil("the Revert button") { app.exists("panel-revert-whereItStands") }
        try app.click("panel-revert-whereItStands")
        try await app.waitUntil("Revert puts back the stored text") { app.text(of: "panel-whereItStands") == "typed in the panel" }
        // Command-Return saves.
        try app.fill("panel-whereItStands", with: "saved with a key")
        app.press(.returnKey, flags: .command)
        try await app.waitUntil("Command-Return saves") {
            ((try? rig.show(plot)).map { string($0, "where_it_stands") }) == "saved with a key"
        }

        // Add a link. The + in the Links header opens the add row, and Add closes it.
        try check(!app.exists("panel-new-link-label"), "the add row shows before the + is pressed")
        try app.click("panel-add-link-open")
        try await app.waitUntil("the add link row") { app.exists("panel-new-link-label") }
        // Ticket 78: the target comes first and has the focus. The label is optional.
        try await app.waitUntil("the target field has the focus") { AccessibilityProbe.shared.isFocused("panel-new-link-target") }
        try check(!AccessibilityProbe.shared.isEnabled("panel-add-link"), "Add is on with empty fields")
        try check(app.exists("panel-add-link-choose"), "the add link row has no Choose button")
        try app.fill("panel-new-link-target", with: "https://example.com/docs")
        // Add is on as soon as the target has text.
        try await app.waitUntil("the Add button is on") { AccessibilityProbe.shared.isEnabled("panel-add-link") }
        try app.fill("panel-new-link-label", with: "Docs")
        try app.click("panel-add-link")
        try await app.waitUntil("the new link in the store") {
            let list = ((try? rig.show(plot))?["links"] as? [[String: Any]]) ?? []
            return list.contains { string($0, "label") == "Docs" }
        }
        try await app.waitUntil("the add link row closes") { !app.exists("panel-new-link-label") }

        // Ticket 78: a link with no label takes one from its target.
        try app.click("panel-add-link-open")
        try await app.waitUntil("the add link row for a link with no label") { app.exists("panel-new-link-target") }
        try app.fill("panel-new-link-target", with: "https://github.com/me/app/issues/3")
        app.press(.returnKey)
        try await app.waitUntil("the link named from its target") {
            let list = ((try? rig.show(plot))?["links"] as? [[String: Any]]) ?? []
            return list.contains { string($0, "label") == "app#3" }
        }
        try await app.waitUntil("the add link row closes again") { !app.exists("panel-new-link-target") }

        // Escape closes the add row and adds nothing.
        try app.click("panel-add-link-open")
        try await app.waitUntil("the add link row again") { app.exists("panel-new-link-label") }
        try app.fill("panel-new-link-label", with: "Never")
        app.press(.escape)
        try await app.waitUntil("Escape closes the add row") { !app.exists("panel-new-link-label") }
        let afterEscape = ((try? rig.show(plot))?["links"] as? [[String: Any]]) ?? []
        try check(!afterEscape.contains { string($0, "label") == "Never" }, "Escape added the link")

        // Add a repo with Return.
        let repo = rig.root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try app.click("panel-add-repo-open")
        try await app.waitUntil("the add repo row") { app.exists("panel-new-repo") }
        try app.fill("panel-new-repo", with: repo.path)
        app.press(.returnKey)
        try await app.waitUntil("the new repo in the store") {
            ((try? rig.show(plot))?["repos"] as? [[String: Any]] ?? []).contains { string($0, "path").hasSuffix("/repo") }
        }
        try await app.waitUntil("the add repo row closes") { !app.exists("panel-new-repo") }

        // Ticket 78: the add repo row offers the git checkouts next to a known repo. Return on a name
        // adds the first suggestion.
        let pickme = rig.root.appendingPathComponent("pickme")
        try FileManager.default.createDirectory(at: pickme.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try app.click("panel-add-repo-open")
        try await app.waitUntil("the pickme suggestion") { app.exists("panel-repo-suggestion-pickme") }
        try check(!app.exists("panel-repo-suggestion-repo"), "the plot's own repo shows as a suggestion")
        try app.fill("panel-new-repo", with: "pickm")
        app.press(.returnKey)
        try await app.waitUntil("pickme in the store") {
            ((try? rig.show(plot))?["repos"] as? [[String: Any]] ?? []).contains { string($0, "path").hasSuffix("/pickme") }
        }
        try await app.waitUntil("the add repo row closes after a suggestion") { !app.exists("panel-new-repo") }
        let pickmeID = ((try rig.show(plot)["repos"] as? [[String: Any]]) ?? [])
            .first { string($0, "path").hasSuffix("/pickme") }.map { string($0, "id") } ?? ""
        try await app.waitUntil("the pickme row") { app.exists("panel-repo-\(pickmeID)") }
        try app.perform("Remove repo", on: "panel-repo-\(pickmeID)")
        try await app.waitUntil("pickme leaves the store") {
            ((try? rig.show(plot))?["repos"] as? [[String: Any]] ?? []).count == 1
        }

        // The row actions of the hover menu and the context menu are also accessibility actions.
        // Remove repo and Remove link run through them.
        let repoID = ((try rig.show(plot)["repos"] as? [[String: Any]]) ?? []).first.map { string($0, "id") } ?? ""
        try await app.waitUntil("the repo row") { app.exists("panel-repo-\(repoID)") }
        try app.perform("Remove repo", on: "panel-repo-\(repoID)")
        try await app.waitUntil("the repo leaves the store") {
            ((try? rig.show(plot))?["repos"] as? [[String: Any]] ?? []).isEmpty
        }
        let docsID = ((try rig.show(plot)["links"] as? [[String: Any]]) ?? [])
            .first { string($0, "label") == "Docs" }.map { string($0, "id") } ?? ""
        try await app.waitUntil("the Docs link row") { app.exists("panel-link-row-\(docsID)") }
        try app.perform("Remove link", on: "panel-link-row-\(docsID)")
        try await app.waitUntil("the Docs link leaves the store") {
            !(((try? rig.show(plot))?["links"] as? [[String: Any]]) ?? []).contains { string($0, "label") == "Docs" }
        }

        // A click on the vault link opens Obsidian.
        try await app.waitUntil("the vault link row") { app.exists("panel-link-\(vaultID)") }
        try app.click("panel-link-\(vaultID)")
        try await app.waitUntil("the obsidian:// call") { rig.openCalls.contains { $0.hasPrefix("obsidian://open?path=") } }
        let call = rig.openCalls.first { $0.hasPrefix("obsidian://open?path=") } ?? ""
        try check(call.contains("Note.md"), "the Obsidian link does not name the note: \(call)")
        Log.line("RESULT open call: \(call)")

        // A missing path shows the box and the Edit link button.
        try app.click("panel-link-\(goneID)")
        try await app.waitUntil("the missing link box") { app.exists("panel-missing-link") && app.exists("panel-missing-edit-link") }
        app.screenshot("panel-missing")
        try check(!rig.openCalls.contains { $0.contains("Gone.md") }, "a missing path reached open")

        // Edit link in the missing box opens the inline editor. Save writes the new label.
        try app.click("panel-missing-edit-link")
        try await app.waitUntil("the link editor") { app.exists("panel-edit-link-label") && !app.exists("panel-missing-link") }
        try app.fill("panel-edit-link-label", with: "Moved note")
        try await app.waitUntil("the Save button is on") { AccessibilityProbe.shared.isEnabled("panel-edit-link-save") }
        try app.click("panel-edit-link-save")
        try await app.waitUntil("the stored label") {
            ((try? rig.show(plot))?["links"] as? [[String: Any]] ?? []).contains { string($0, "label") == "Moved note" }
        }
        try await app.waitUntil("the editor closes") { !app.exists("panel-edit-link-label") }

        // A clash: edit What, change it from the CLI, then save.
        try app.fill("panel-what", with: "mine")
        try await app.waitUntil("the Save button for What") { app.exists("panel-save-what") }
        try rig.loam(["set", plot, "what", "theirs"])
        await app.sleep(1)
        try app.click("panel-save-what")
        try await app.waitUntil("the clash box") { app.exists("panel-clash") }
        app.screenshot("panel-clash")
        try app.click("panel-clash-keep-mine")
        try await app.waitUntil("the stored What is mine") { ((try? rig.show(plot)).map { string($0, "what") }) == "mine" }
    }

    /// Ticket 36: a change by Claude shows as new, Undo reverts it, a clash asks, closing marks it seen.
    static func panelReview(_ app: DriverApp) async throws {
        do { try await panelReviewSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func panelReviewSteps(_ app: DriverApp) async throws {
        let rig = try PanelRig(outFolder: app.outFolder)
        let plot = try rig.newPlot("Review plot")
        let other = try rig.newPlot("Other plot")
        try rig.loam(["set", plot, "where-it-stands", "before"])

        let host = try await app.launchApp(client: rig.client, state: rig.stateFile)
        try await app.openPanel(host)
        try check(!app.exists("panel-new-since"), "the new box shows before any change by Claude")

        // 1. Claude changes where-it-stands.
        try await rig.claudeSetsWhere(plot, "claude wrote this")
        let first = try rig.lastChangeID(plot)
        try await app.waitUntil("the new box and its row") { app.exists("panel-new-since") && app.exists("change-new-\(first)") }
        try await app.waitUntil("the panel button count") { app.text(of: "panel-button") == "Plot panel \u{2318}I \u{00B7} 1" }
        app.screenshot("new-since")

        // 2. Undo reverts it.
        try app.click("change-undo-\(first)")
        try await app.waitUntil("where-it-stands is back") {
            ((try? rig.show(plot)).map { string($0, "where_it_stands") }) == "before"
        }
        try await app.waitUntil("undone in the log") {
            app.exists("change-log-\(first)") && app.exists("change-undone-\(first)")
        }
        app.screenshot("undone")

        // Ticket 72: in the log the diff hides behind a disclosure chevron.
        try check(!app.exists("change-diff-log-\(first)"), "the log shows the diff before the chevron is pressed")
        try app.click("change-disclose-\(first)")
        try await app.waitUntil("the diff in the log") { app.exists("change-diff-log-\(first)") }
        try app.click("change-disclose-\(first)")
        try await app.waitUntil("the diff closes") { !app.exists("change-diff-log-\(first)") }

        // 3. Undo clash: a later change by the CLI edits the same item.
        try await rig.claudeSetsWhere(plot, "claude again")
        let second = try rig.lastChangeID(plot)
        try rig.loam(["set", plot, "where-it-stands", "cli later"])
        try await app.waitUntil("the second change row") { app.exists("change-undo-\(second)") }
        try app.click("change-undo-\(second)")
        try await app.waitUntil("the undo clash") { app.exists("undo-clash") }
        await app.sleep(0.5)
        app.screenshot("undo-clash")
        try app.click("undo-clash-cancel")
        await app.sleep(0.5)
        try check(string(try rig.show(plot), "where_it_stands") == "cli later", "cancel changed the plot")
        try app.click("change-undo-\(second)")
        try await app.waitUntil("the undo clash again") { app.exists("undo-clash-overwrite") }
        try app.click("undo-clash-overwrite")
        try await app.waitUntil("the overwrite wrote the old value") {
            ((try? rig.show(plot)).map { string($0, "where_it_stands") }) == "before"
        }

        // 4. Closing the panel marks every change seen.
        let newest = try rig.lastChangeID(plot)
        await app.sleep(0.5)
        try app.pressMenuKey("i")
        try await app.waitUntil("last_seen_changes holds the newest change") {
            (rig.stateFile.lastSeenChanges() ?? [:])[plot] == newest
        }
        try await app.waitUntil("the panel is closed") { !app.exists("panel-whereItStands") }
        await app.sleep(0.5)
        try app.pressMenuKey("i")
        try await app.waitUntil("the panel shows again") { app.exists("panel-whereItStands") }
        await app.sleep(0.5)
        try check(!app.exists("panel-new-since"), "the new box shows after the changes were seen")

        // 5. A plot that is not active shows its count in the sidebar.
        try app.pressMenuKey("i")
        try await app.waitUntil("the panel is closed again") { !app.exists("panel-whereItStands") }
        await app.sleep(0.5)
        host.model.activate(number: 2)
        try await app.waitUntil("the other plot is active") { host.model.workspace.activePlotID == other }
        try await rig.claudeSetsWhere(plot, "while you were away")
        // The sidebar row combines its children into one element, so the count
        // is part of the row text and `plot-new-changes-<plot>` has no element of its own.
        try await app.waitUntil("the sidebar count") {
            app.text(of: "plot-\(plot)")?.contains("\u{270E} 1") == true
        }
        Log.line("RESULT sidebar row: \(app.text(of: "plot-\(plot)") ?? "")")
        app.screenshot("sidebar-count")

        // 6. The log shows ten changes to a page, and the pager moves to older and newer pages.
        for n in try rig.changes(plot).count..<13 { try rig.loam(["set", plot, "where-it-stands", "cli \(n)"]) }
        let total = try rig.changes(plot).count
        host.model.activate(number: 1)
        try await app.waitUntil("the review plot is active") { host.model.workspace.activePlotID == plot }
        await app.sleep(0.5)
        try app.pressMenuKey("i")
        try await app.waitUntil("the first page") { app.text(of: "change-log-range") == "1 to 10 of \(total)" }
        let oldest = try rig.changes(plot).compactMap { $0["id"] as? Int }.min() ?? 0
        try check(!app.exists("change-log-\(oldest)"), "the first page shows the oldest change")
        scrollPanel(host, toEnd: true)
        await app.sleep(0.3)
        app.screenshot("log-page-1")
        try app.click("change-log-older")
        try await app.waitUntil("the second page") { app.text(of: "change-log-range") == "11 to \(total) of \(total)" }
        try await app.waitUntil("the oldest change on the second page") { app.exists("change-log-\(oldest)") }
        scrollPanel(host, toEnd: true)
        await app.sleep(0.3)
        app.screenshot("log-page-2")
        try app.click("change-log-newer")
        try await app.waitUntil("back on the first page") { app.text(of: "change-log-range") == "1 to 10 of \(total)" }
    }
}
