import AppKit
import IOSurface
import LoamKit
import LoamTerminal

/// Driver scenarios for the Ghostty config and keys (spec 8.3). Each one uses the driver's
/// own config file in the out folder, never your Ghostty config.
@MainActor
extension Scenarios {
    /// A change to the config file reloads it, and the pane redraws with the new background.
    /// A config with errors keeps the last good one. ⌘⇧, reloads. A clash is in the load.
    static func configReload(_ app: DriverApp) async throws {
        var loads: [ConfigLoad] = []
        app.runtime.onConfigLoad = {
            loads.append($0)
            Log.line("config load \(loads.count): \($0.outcome), window background #\(rgb(app.runtime.windowAppearance.background))")
        }
        let pane = try app.addPane("A", command: "/bin/sh -c 'sleep 60'")
        try await app.waitUntil("the first frame") { app.backgroundPixel(pane) != nil }
        Log.line("first background \(app.backgroundPixel(pane).map(hex) ?? "?")")

        // A new background in the file: the watch reloads, and the pane redraws.
        for color in ["204060", "a03050"] {
            try app.writeConfig("background = #\(color)")
            do {
                try await app.waitUntil("the pane redraws with #\(color)", timeout: 10) {
                    app.backgroundPixel(pane).map { close($0, color) } ?? false
                }
            } catch {
                throw DriverFailure("\(error). The pane pixel is #\(app.backgroundPixel(pane).map(hex) ?? "?")")
            }
            try check(rgb(app.runtime.windowAppearance.background) == color, "the window appearance has the old background")
            app.screenshot("background-\(color)")
        }
        try check(loads.last?.outcome == .applied, "the reload was not applied: \(String(describing: loads.last?.outcome))")

        // A config with an error keeps the last good one, and the load reports the error.
        let before = loads.count
        try app.writeConfig("background = #00ff00\nno-such-option = 1")
        try await app.waitUntil("the load with an error") { loads.count > before }
        guard case .keptLastGood(let errors) = loads.last!.outcome else {
            throw DriverFailure("a config with an error was applied: \(loads.last!.outcome)")
        }
        Log.line("errors: \(errors.joined(separator: "; "))")
        try check(errors.contains { $0.contains("no-such-option") }, "the errors do not name the bad line")
        await app.sleep(0.5)
        try check(app.backgroundPixel(pane).map { close($0, "a03050") } ?? false, "the pane lost the last good background")
        try check(rgb(app.runtime.windowAppearance.background) == "a03050", "the window lost the last good background")

        // A fixed config applies again.
        try app.writeConfig("background = #305020")
        try await app.waitUntil("the pane redraws with #305020") { app.backgroundPixel(pane).map { close($0, "305020") } ?? false }
        try check(app.runtime.configDiagnostics.isEmpty, "the fixed config still has errors")

        // A keybind of a Loam key shows as a clash.
        let beforeClash = loads.count
        try app.writeConfig("background = #305020\nkeybind = cmd+p=new_split:right")
        try await app.waitUntil("the reload with the keybind") { loads.count > beforeClash }
        await app.sleep(0.5)

        // ⌘⇧, reloads with no file change.
        let beforeKey = loads.count
        app.press(letter: ",", flags: [.command, .shift])
        try await app.waitUntil("the reload from ⌘⇧,") { loads.count > beforeKey }
        let clashes = loads.last!.clashes
        try check(clashes.count == 1 && clashes[0].key.chord == KeyChord(.command, "p"), "the clash is missing: \(clashes)")
        Log.line("clash: \(clashes[0])")
        app.screenshot("reloaded")
        _ = await app.close(pane)
    }

    /// The key routing: Ghostty's tab and split keys reach Loam as actions, a rebind works,
    /// Loam's fixed keys win over a clash, and ⌘Z goes on to the terminal when nothing is undone.
    static func keys(_ app: DriverApp) async throws {
        try app.writeConfig("keybind = cmd+p=new_split:right\nkeybind = cmd+y=new_tab")
        app.runtime.reloadConfig()
        try check(app.runtime.lastConfigLoad.clashes.map(\.key.command) == [.quickSwitcher], "no clash for ⌘P")

        var commands: [AppCommand] = []
        app.runtime.commandHandler = { command in
            commands.append(command)
            return command != .undo && command != .redo
        }
        let pane = try app.addPane("A", command: "/bin/zsh -f", env: ["LANG": "en_US.UTF-8"])
        var closeRequests = 0
        pane.onCloseRequest = { _ in closeRequests += 1 }
        try await app.waitForPrompt(pane)

        let presses: [(Character, NSEvent.ModifierFlags, AppCommand, String)] = [
            ("t", .command, .newTab, "⌘T"),
            ("y", .command, .newTab, "⌘Y (a rebind)"),
            ("d", .command, .newSplit(.sideBySide), "⌘D"),
            ("d", [.command, .shift], .newSplit(.stacked), "⌘⇧D"),
            ("[", .command, .focusPane(.previous), "⌘["),
            ("]", .command, .focusPane(.next), "⌘]"),
            ("[", [.command, .shift], .previousTab, "⌘⇧["),
            ("]", [.command, .shift], .nextTab, "⌘⇧]"),
            ("1", .command, .selectTab(1), "⌘1"),
            ("8", .command, .selectTab(8), "⌘8"),
            ("9", .command, .lastTab, "⌘9"),
            ("t", [.command, .shift], .undo, "⌘⇧T"),
            ("z", .command, .undo, "⌘Z"),
            ("z", [.command, .shift], .redo, "⌘⇧Z"),
            // Loam's fixed keys.
            ("p", .command, .quickSwitcher, "⌘P (bound to new_split in the config)"),
            ("p", [.command, .shift], .quickSwitcherActions, "⌘⇧P"),
            ("l", .command, .nextPaneThatNeedsYou, "⌘L"),
            ("n", .command, .newPlot, "⌘N"),
            ("b", .command, .toggleSidebar, "⌘B"),
            ("i", .command, .togglePlotPanel, "⌘I"),
            ("t", [.command, .option], .newShellTab, "⌘⌥T"),
            ("d", [.control, .command], .newShellSplit(.sideBySide), "⌃⌘D"),
            ("d", [.control, .command, .shift], .newShellSplit(.stacked), "⌃⌘⇧D"),
            ("1", .control, .selectPlot(1), "⌃1"),
            ("9", .control, .selectPlot(9), "⌃9"),
        ]
        for (letter, flags, expected, name) in presses {
            commands.removeAll()
            app.press(letter: letter, flags: flags)
            try await app.waitUntil("\(name) runs \(expected)", timeout: 3) { !commands.isEmpty }
            await app.sleep(0.05)
            try check(commands == [expected], "\(name) ran \(commands), not \(expected)")
        }

        // ⌘W closes the pane through libghostty's close request.
        app.press(letter: "w", flags: .command)
        try await app.waitUntil("⌘W asks to close the pane") { closeRequests == 1 }

        // The menu shows the key of each Ghostty action, but never a Loam key.
        let newTab = app.runtime.chord(forGhosttyAction: "new_tab")
        let nextSplit = app.runtime.chord(forGhosttyAction: "goto_split:next")
        let splitRight = LoamKeys.menuChord(forGhosttyBinding: app.runtime.chord(forGhosttyAction: "new_split:right"))
        Log.line("menu keys: new_tab \(newTab.map(\.description) ?? "none"), goto_split:next "
            + "\(nextSplit.map(\.description) ?? "none"), new_split:right \(splitRight.map(\.description) ?? "none")")
        try check(nextSplit == KeyChord(.command, "]"), "goto_split:next is not on ⌘]")
        try check(newTab == KeyChord(.command, "t") || newTab == KeyChord(.command, "y"), "new_tab has no key")
        try check(splitRight != KeyChord(.command, "p"), "the menu shows Loam's ⌘P for a Ghostty action")
        _ = await app.close(pane)
    }
}

private func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw DriverFailure(message()) }
}

private func hex(_ pixel: (Int, Int, Int)) -> String { String(format: "%02x%02x%02x", pixel.0, pixel.1, pixel.2) }

/// True when the pixel is within 4 of the sRGB colour on each channel, in sRGB or in Display P3.
/// The renderer writes Display P3 values to its surface (#204060 is #283f5d), and it can round.
private func close(_ pixel: (Int, Int, Int), _ color: String) -> Bool {
    let value = Int(color, radix: 16)!
    let srgb = NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    return [srgb, srgb.usingColorSpace(.displayP3)].compactMap { $0 }.contains { target in
        let channels = [target.redComponent, target.greenComponent, target.blueComponent].map { Int(($0 * 255).rounded()) }
        return abs(pixel.0 - channels[0]) <= 4 && abs(pixel.1 - channels[1]) <= 4 && abs(pixel.2 - channels[2]) <= 4
    }
}

private func rgb(_ color: NSColor) -> String {
    guard let srgb = color.usingColorSpace(.sRGB) else { return "?" }
    return hex((Int((srgb.redComponent * 255).rounded()), Int((srgb.greenComponent * 255).rounded()),
                Int((srgb.blueComponent * 255).rounded())))
}

@MainActor
extension DriverApp {
    /// Writes the driver config: the base lines, then `extra`.
    func writeConfig(_ extra: String) throws {
        try (Self.baseConfig + extra + "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
        Log.line("config: \(extra.replacingOccurrences(of: "\n", with: "; "))")
    }

    /// A pixel near the bottom right of the pane's last frame, away from any text. It reads the
    /// IOSurface that libghostty presents, so it needs no screen recording access.
    func backgroundPixel(_ pane: TerminalSurfaceView) -> (Int, Int, Int)? {
        guard let contents = pane.layer?.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
        let surface = unsafeDowncast(contents as AnyObject, to: IOSurface.self)
        _ = surface.lock(options: .readOnly, seed: nil)
        defer { _ = surface.unlock(options: .readOnly, seed: nil) }
        let width = surface.width, height = surface.height
        guard width > 20, height > 20 else { return nil }
        let x = width - 10, y = height - 10
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let offset = y * surface.bytesPerRow + x * 4
        // BGRA.
        return (Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset]))
    }
}
