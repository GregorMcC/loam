import AppKit
import GhosttyKit
import LoamKit
import LoamTerminal

/// One driver scenario. Keep each one short: a few seconds of real time.
struct Scenario {
    let name: String
    /// The time limit in seconds. Past it, the driver exits with code 4.
    let limit: TimeInterval
    let body: @MainActor (DriverApp) async throws -> Void
}

/// Shells with no startup files, so runs cost no usage and do not depend on
/// your shell setup. macOS bash 3.2 has no bracketed paste, so a multi-line
/// paste into it is unsafe and shows the prompt.
private let zsh = "/bin/zsh -f"
private let bash = "/bin/bash --noprofile --norc"
private let utf8 = ["LANG": "en_US.UTF-8"]

private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw DriverFailure(message()) }
}

@MainActor
enum Scenarios {
    static let all: [Scenario] = [
        Scenario(name: "type", limit: 30, body: type),
        Scenario(name: "paste", limit: 30, body: paste),
        Scenario(name: "select-copy", limit: 30, body: selectCopy),
        Scenario(name: "scroll", limit: 30, body: scroll),
        Scenario(name: "resize", limit: 30, body: resize),
        Scenario(name: "close-streaming", limit: 30, body: closeStreaming),
        Scenario(name: "spam", limit: 30, body: spam),
        Scenario(name: "env", limit: 30, body: env),
        Scenario(name: "panel-edit", limit: 60, body: panelEdit),
        Scenario(name: "panel-review", limit: 60, body: panelReview),
        Scenario(name: "panel-shot", limit: 90, body: panelShot),
        Scenario(name: "config-reload", limit: 45, body: configReload),
        Scenario(name: "keys", limit: 45, body: keys),
        Scenario(name: "switcher", limit: 60, body: switcher),
        Scenario(name: "theme", limit: 45, body: theme),
        Scenario(name: "pane-resources", limit: 60, body: paneResources),
        Scenario(name: "window-shot", limit: 90, body: windowShot),
        Scenario(name: "empty-hint", limit: 60, body: emptyHint),
        Scenario(name: "frame-shot", limit: 90, body: frameShot),
        Scenario(name: "actions", limit: 120, body: actions),
        Scenario(name: "sidebar-shot", limit: 90, body: sidebarShot),
        Scenario(name: "panes", limit: 90, body: panes),
        Scenario(name: "worktrees", limit: 120, body: worktrees),
        Scenario(name: "archive", limit: 120, body: archive),
        Scenario(name: "restore-quit", limit: 90, body: restoreQuit),
        Scenario(name: "restore-relaunch", limit: 90, body: restoreRelaunch),
        Scenario(name: "attention", limit: 120, body: attention),
        Scenario(name: "settings", limit: 60, body: settings),
        Scenario(name: "tab-close", limit: 90, body: tabClose),
        Scenario(name: "readme-shots", limit: 1200, body: readmeShots),
    ]

    /// Typing through the real key path: plain keys, shift, control, and a
    /// composed character through NSTextInputClient.
    static func type(_ app: DriverApp) async throws {
        let pane = try app.addPane("A", command: zsh, env: utf8)
        try await app.waitForPrompt(pane)

        try app.type("echo typed-$((6*7))")
        app.press(.returnKey)
        try await app.waitUntil("typed-42 in the output") { app.lines(pane).contains("typed-42") }

        // Control-U deletes the line in zsh, so only the second command runs.
        try app.type("echo wrong")
        app.press(letter: "u", flags: .control)
        try app.type("echo Ctrl-OK")
        app.press(.returnKey)
        try await app.waitUntil("Ctrl-OK in the output") { app.lines(pane).contains("Ctrl-OK") }
        try require(!pane.screenText().contains("wrongecho"), "control-U did not delete the line")

        // An input method composes é from a dead key: marked text first, then the commit.
        try app.type("echo caf")
        let none = NSRange(location: NSNotFound, length: 0)
        pane.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        try require(pane.hasMarkedText(), "the marked text did not stay")
        app.screenshot("ime-marked")
        pane.insertText("é", replacementRange: none)
        try require(!pane.hasMarkedText(), "the commit did not clear the marked text")

        // A Japanese input method: two marked steps, then the commit of 2 characters.
        try app.type(" ")
        pane.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        pane.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
        pane.insertText("日本", replacementRange: none)
        app.press(.returnKey)
        try await app.waitUntil("café 日本 in the output") { app.lines(pane).contains("café 日本") }
        app.screenshot("typed")
        _ = await app.close(pane)
    }

    /// A safe paste goes in at once. An unsafe one shows the prompt, and goes in
    /// only when you confirm it.
    static func paste(_ app: DriverApp) async throws {
        let pane = try app.addPane("A", command: bash)
        try await app.waitForPrompt(pane)
        var prompts: [ClipboardConfirmation] = []
        pane.onClipboardConfirmation = { prompts.append($0) }
        let pasteboard = app.runtime.pasteboard

        func put(_ text: String) {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        put("echo pasted-ok")
        app.press(letter: "v", flags: .command)
        try await app.waitUntil("the safe paste on the command line") { pane.screenText().contains("echo pasted-ok") }
        try require(prompts.isEmpty, "a safe paste showed the prompt")
        app.press(.returnKey)
        try await app.waitUntil("pasted-ok in the output") { app.lines(pane).contains("pasted-ok") }

        put("echo unsafe-1\necho unsafe-2\n")
        app.press(letter: "v", flags: .command)
        try await app.waitUntil("the paste prompt") { prompts.count == 1 }
        try require(prompts[0].kind == .paste, "the prompt is not for a paste")
        try require(prompts[0].preview.contains("echo unsafe-2"), "the prompt does not show the text")
        try require(pane.pendingClipboardConfirmation === prompts[0], "the pane has no pending prompt")
        await app.sleep(0.3)
        try require(!pane.screenText().contains("unsafe-1"), "the unsafe paste went in before the answer")
        app.screenshot("paste-prompt")
        prompts[0].respond(true)
        try await app.waitUntil("unsafe-2 in the output") { app.lines(pane).contains("unsafe-2") }

        put("echo denied-paste\n")
        app.press(letter: "v", flags: .command)
        try await app.waitUntil("the second paste prompt") { prompts.count == 2 }
        prompts[1].respond(false)
        await app.sleep(0.5)
        try require(!pane.screenText().contains("denied-paste"), "a denied paste went in")
        app.screenshot("pasted")

        // A file dropped on the pane goes in as its shell-escaped path, as in Ghostty. Claude Code
        // attaches a dropped image from that path.
        try require(Set(pane.registeredDraggedTypes).isSuperset(of: [.fileURL, .string]), "the pane takes no drops")
        app.press(letter: "u", flags: .control)  // Clear the command line.
        let dropped = NSPasteboard(name: NSPasteboard.Name("loam-driver-drop-\(UUID().uuidString)"))
        dropped.clearContents()
        dropped.writeObjects([URL(fileURLWithPath: "/tmp/loam drop/shot (1).png") as NSURL])
        try require(pane.drop(dropped), "the pane refused the drop")
        try await app.waitUntil("the dropped path on the command line") {
            pane.screenText().contains(#"/tmp/loam\ drop/shot\ \(1\).png"#)
        }
        dropped.releaseGlobally()
        _ = await app.close(pane)
    }

    /// A mouse drag selects text, and command-C copies it.
    static func selectCopy(_ app: DriverApp) async throws {
        let pane = try app.addPane("A", command: zsh)
        try await app.waitForPrompt(pane)
        let word = "SELECT-ME-PLEASE"
        try app.type("print \(word)")
        app.press(.returnKey)
        try await app.waitUntil("\(word) in the output") { app.lines(pane).contains(word) }
        guard let row = app.lines(pane).firstIndex(of: word) else { throw DriverFailure("no output row") }

        let last = Double(word.count - 1)
        app.mouse(.leftMouseDown, at: try app.windowPoint(pane, column: -0.3, row: Double(row)))
        for column in stride(from: 0.0, through: last, by: 1) {
            app.mouse(.leftMouseDragged, at: try app.windowPoint(pane, column: column, row: Double(row)))
            await app.sleep(0.01)
        }
        let end = try app.windowPoint(pane, column: last + 0.3, row: Double(row))
        app.mouse(.leftMouseDragged, at: end)
        app.mouse(.leftMouseUp, at: end)
        try await app.waitUntil("the selection is \(word)") { pane.selectionText() == word }
        app.screenshot("selected")

        app.press(letter: "c", flags: .command)
        try await app.waitUntil("the clipboard holds \(word)") {
            app.runtime.pasteboard.string(forType: .string) == word
        }
        _ = await app.close(pane)
    }

    /// Trackpad scroll, then momentum scroll, move the viewport up the scrollback.
    static func scroll(_ app: DriverApp) async throws {
        let pane = try app.addPane("A", command: zsh)
        try await app.waitForPrompt(pane)
        try app.type("seq 1 400")
        app.press(.returnKey)
        try await app.waitUntil("400 in the output") { app.lines(pane).contains("400") }
        try await app.waitForPrompt(pane)

        func top() -> Int { app.lines(pane).compactMap { Int($0) }.first ?? Int.max }
        let bottom = top()
        Log.line("top line before the scroll: \(bottom)")

        // Fingers on the trackpad: began, changed, ended.
        app.scroll(pane, pixels: 0, phase: 1)
        for _ in 0..<5 { app.scroll(pane, pixels: 40, phase: 2) }
        app.scroll(pane, pixels: 0, phase: 4)
        try await app.waitUntil("the viewport moved up") { top() < bottom }
        let afterScroll = top()
        Log.line("top line after the scroll: \(afterScroll)")

        // Fingers off: the momentum phase continues the scroll.
        app.scroll(pane, pixels: 40, momentum: 1)
        for _ in 0..<5 { app.scroll(pane, pixels: 40, momentum: 2) }
        app.scroll(pane, pixels: 0, momentum: 3)
        try await app.waitUntil("momentum moved the viewport up") { top() < afterScroll }
        Log.line("top line after momentum: \(top())")
        app.screenshot("scrolled")
        _ = await app.close(pane)
    }

    /// A smaller window gives the pane fewer columns, and the shell sees the new size.
    static func resize(_ app: DriverApp) async throws {
        let pane = try app.addPane("A", command: zsh)
        try await app.waitForPrompt(pane)
        guard let before = pane.size else { throw DriverFailure("the pane has no size") }
        let scale = app.window.backingScaleFactor
        try require(before.width_px == UInt32(pane.bounds.width * scale), "the pixel width does not match the scale")

        app.window.setContentSize(NSSize(width: 600, height: 400))
        app.layoutPanes()
        try await app.waitUntil("fewer columns") { (pane.size?.columns ?? before.columns) < before.columns }
        guard let after = pane.size else { throw DriverFailure("the pane has no size") }
        Log.line("grid \(before.columns)x\(before.rows) to \(after.columns)x\(after.rows)")

        // libghostty sends the PTY resize after a short coalescing delay.
        await app.sleep(0.5)
        try app.type("stty size")
        app.press(.returnKey)
        let expected = "\(after.rows) \(after.columns)"
        try await app.waitUntil("stty size is \(expected)") { app.lines(pane).contains(expected) }
        _ = await app.close(pane)
    }

    /// Two panes stream output. Both close with the safe order, at the same time, with no hang.
    static func closeStreaming(_ app: DriverApp) async throws {
        let a = try app.addPane("A", command: zsh)
        let b = try app.addPane("B", command: "/bin/zsh -fc 'while :; do print streaming-b $RANDOM; done'")
        app.window.makeFirstResponder(a)
        try await app.waitForPrompt(a)
        // A shell with a job in the foreground: the close must end the job and the shell.
        try app.type("seq 1 999999999")
        app.press(.returnKey)
        try await app.waitUntil("A streams") { app.lines(a).compactMap { Int($0) }.count > 5 }
        let aStreams = await app.isStreaming(a)
        let bStreams = await app.isStreaming(b)
        try require(aStreams && bStreams, "the panes do not stream (A \(aStreams), B \(bStreams))")
        app.screenshot("streaming")

        let start = ProcessInfo.processInfo.systemUptime
        // Start both closes before either one ends.
        var results: [TerminalSurfaceView.CloseResult] = []
        for pane in [a, b] {
            Task { @MainActor in results.append(await app.close(pane)) }
        }
        try await app.waitUntil("both panes closed", timeout: 8) { results.count == 2 }
        let total = ProcessInfo.processInfo.systemUptime - start
        Log.line(String(format: "both panes closed in %.3f s", total))
        for result in results {
            try require(!result.forced, "a pane did not exit")
            try require(result.waited < 2, "a pane needed SIGKILL")
        }
        try require(total < 3, "the closes took \(total) s")
    }

    /// The spike's spam-naive scenario (ghostty-org/ghostty#14245): a pane sets
    /// its title in a loop. A direct free hangs. The safe order closes it.
    static func spam(_ app: DriverApp) async throws {
        let a = try app.addPane("A", command: #"/bin/zsh -fc 'while :; do printf "\e]0;t%s\a" $RANDOM; done'"#)
        let b = try app.addPane("B", command: zsh)
        await app.sleep(3)
        let titles = app.runtime.actionCounts[GHOSTTY_ACTION_SET_TITLE.rawValue] ?? 0
        Log.line("title actions so far: \(titles)")
        try require(titles > 100, "the title loop did not run")
        app.screenshot("spam")

        let result = await app.close(a)
        try require(!result.forced && result.waited < 2, "the title loop did not exit on SIGHUP")
        Log.line(String(format: "RESULT spam safe close returned after %.3f s", result.waited + result.free))

        // The other pane still works.
        app.window.makeFirstResponder(b)
        try await app.waitForPrompt(b)
        try app.type("echo still-alive")
        app.press(.returnKey)
        try await app.waitUntil("pane B still answers") { app.lines(b).contains("still-alive") }
        _ = await app.close(b)
    }

    /// The pane gets a clean environment plus its own variables (spec 8.2).
    static func env(_ app: DriverApp) async throws {
        let file = "\(app.outFolder)/pane-env.txt"
        try? FileManager.default.removeItem(atPath: file)
        let pane = try app.addPane("A", command: "/bin/sh -c 'env > pane-env.txt; echo env-written; sleep 30'")
        try await app.waitUntil("env-written") { app.lines(pane).contains("env-written") }
        let text = try String(contentsOfFile: file, encoding: .utf8)
        let keys = Set(text.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        // libghostty sets TERM, TERM_PROGRAM, and GHOSTTY_* itself. Check the rest.
        let leaked = keys.filter { PaneEnvironment.isLeaked($0) && ($0.hasPrefix("CLAUDE") || $0.hasPrefix("SUPACODE_")) }
        try require(leaked.isEmpty, "leaked into the pane: \(leaked.sorted())")
        try require(!text.contains("loam-test-leak"), "an inherited GHOSTTY_RESOURCES_DIR or TERMINFO leaked")
        try require(keys.contains("LOAM_DRIVER_PANE"), "the pane variable is missing")
        // Loam sets its own resources folder, so libghostty finds the themes, the shell
        // integration, and the terminfo. Then the pane has TERM=xterm-ghostty.
        let environment = ProcessInfo.processInfo.environment
        let resources = TerminalRuntime.resourcesFolder()
        try require(resources != nil, "no Ghostty resources folder. Run scripts/build-ghosttykit.sh")
        try require(environment[TerminalRuntime.resourcesVariable] == resources, "the app has another resources folder")
        try require(text.contains("GHOSTTY_RESOURCES_DIR=\(resources!)\n"), "the pane has another resources folder")
        try require(text.contains("TERM=xterm-ghostty\n"), "the pane has no xterm-ghostty TERM")
        let ownLeaks = PaneEnvironment.keysToRemove(from: environment).filter { $0 != TerminalRuntime.resourcesVariable }
        try require(ownLeaks.isEmpty, "the app process still has \(ownLeaks.sorted())")
        _ = await app.close(pane)
    }
}
