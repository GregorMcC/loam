import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 72: the plot panel with a full plot, at 260 px and at its widest, 520 px,
/// in Night, Day, and Dracula after a config reload, and with an edit clash open. It checks that the
/// panel ground follows the reload at once. The panes run the frame-shot demo script.
@MainActor
extension Scenarios {
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func panelShot(_ app: DriverApp) async throws {
        do { try await panelShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func panelShotSteps(_ app: DriverApp) async throws {
        let fm = FileManager.default
        let (rig, environment, config) = try shotRig(app)

        let plot = try rig.newPlot("Loam v1 build")
        // Two repos: the main repo on branch main, for the window subtitle, and the website.
        let repo = rig.root.appendingPathComponent("loam")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try rig.loam(["repo", "add", plot, repo.path])
        let site = rig.root.appendingPathComponent("loam-site")
        try fm.createDirectory(at: site, withIntermediateDirectories: true)
        try rig.loam(["repo", "add", plot, site.path])
        // A long brief.
        try rig.loam(["set", plot, "what", "A macOS terminal on libghostty that seeds Claude Code sessions. "
            + "Each plot holds a brief, its repos, and its links, and each session starts with them."])
        try rig.loam(["set", plot, "why", "Each session knows the purpose and the key documents at once, "
            + "so you do not paste the same context into every new session."])
        try rig.loam(["set", plot, "where-it-stands", "The frame and the color are done."])
        // Three links, one with a missing path.
        let note = rig.vault.appendingPathComponent("Notes/Note.md").path
        try rig.loam(["link", "add", plot, "Design spec", note, "--note", "The source of truth"])
        try rig.loam(["link", "add", plot, "Repository", "https://github.com/GregorMcC/loam"])
        try rig.loam(["link", "add", plot, "Design pack", "/nonexistent-loam-driver/Design pack"])
        _ = try rig.newPlot("Client onboarding")
        _ = try rig.newPlot("Release notes")

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        try await app.waitUntil("a plot is active") { host.model.workspace.activePlotID != nil }
        host.model.activate(number: 1)
        host.model.openTab()
        host.model.split(.sideBySide)
        host.model.selectTab(number: 1)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        let height = min(940, screen.height - 60)
        host.window.setFrame(NSRect(x: screen.minX + 40, y: screen.maxY - height - 20, width: 1240, height: height), display: true)
        try await app.openPanel(host)

        // The change log: a change by Claude, undone. Closing the panel marks it seen. Then a second
        // change by Claude shows as new.
        try await rig.claudeSetsWhere(plot, "The panel is next.")
        let first = try rig.lastChangeID(plot)
        try rig.loam(["undo", "\(first)", "--actor", "app"])
        try await app.waitUntil("the undone change") {
            host.model.review.log(plot: plot).first { $0.id == first }.map { host.model.review.undoneNote($0) != nil } ?? false
        }
        try app.pressMenuKey("i")
        try await app.waitUntil("the panel is closed") { !app.exists("panel-whereItStands") }
        await app.sleep(0.4)
        try app.pressMenuKey("i")
        try await app.waitUntil("the panel shows again") { app.exists("panel-whereItStands") }
        try await rig.claudeSetsWhere(plot, "The frame and the color are done. The plot panel now uses native "
            + "form sections. Next: check the panel at 260 and 520 px in Night, Day, and a dark theme.")
        try await app.waitUntil("the new change", timeout: 10) { app.exists("panel-new-since") }

        try await app.waitUntil("2 demo panes ran", timeout: 15) {
            ((try? fm.contentsOfDirectory(atPath: "\(app.outFolder)/demo-runs"))?.count ?? 0) >= 2
        }
        /// Sets Night or Day and waits until the focused pane follows, as `frame-shot` does. A single
        /// theme stays dark in Day, so a timeout does not fail the run.
        func appearance(_ name: NSAppearance.Name) async {
            NSApp.appearance = NSAppearance(named: name)
            let pane = host.model.workspace.selectedTab(of: plot)?.focused
            try? await app.waitUntil("the pane follows \(name.rawValue)", timeout: 10) {
                guard let view = pane.flatMap({ host.paneView($0) as? TerminalSurfaceView }),
                      let pixel = app.backgroundPixel(view) else { return false }
                return (pixel.0 + pixel.1 + pixel.2 < 3 * 128) == (name == .darkAqua)
            }
            await app.sleep(0.5)
        }

        func shots(_ name: String) async throws {
            for width in [260.0, 520.0] {
                setPanelWidth(host, width)
                scrollPanel(host, toEnd: false)
                await app.sleep(0.8)
                app.screenshot("\(name)-\(Int(width))")
                // The form builds rows as they come into view, so the end can move once.
                scrollPanel(host, toEnd: true)
                await app.sleep(0.3)
                scrollPanel(host, toEnd: true)
                await app.sleep(0.8)
                app.screenshot("\(name)-\(Int(width))-end")
            }
            scrollPanel(host, toEnd: false)
        }

        await appearance(.darkAqua)
        try await shots("night")
        await appearance(.aqua)
        try await shots("day")

        // A config reload with Dracula: the panel ground follows at once.
        await appearance(.darkAqua)
        try app.writeConfig(config + "\ntheme = Dracula\n")
        app.runtime.reloadConfig()
        try await app.waitUntil("the chrome follows Dracula (#282a36)", timeout: 10) {
            ChromePalette.shared.current?.bedrock == 0x282a36
        }
        let want = ChromeSurfaces.derive(background: 0x282a36).horizonA
        setPanelWidth(host, 520)
        await app.sleep(0.8)
        let ground = try panelGround(app, host)
        Log.line("RESULT panel ground after the reload: \(ground), want \(String(format: "%06x", want))")
        try expect(near(ground, want), "the panel ground \(ground) is not the Dracula horizon-a")
        try await shots("dracula")

        // A third-party theme (ticket 87): Catppuccin Mocha, then the same one translucent.
        try app.writeConfig(config + "\ntheme = Catppuccin Mocha\n")
        app.runtime.reloadConfig()
        try await app.waitUntil("the chrome follows Catppuccin Mocha (#1e1e2e)", timeout: 10) {
            ChromePalette.shared.current?.bedrock == ChromeSurfaces.derive(background: 0x1e1e2e).bedrock
        }
        try await shots("catppuccin")
        try app.writeConfig(config + "\ntheme = Catppuccin Mocha\nbackground-opacity = 0.8\nbackground-blur = 20\n")
        app.runtime.reloadConfig()
        try await app.waitUntil("the window turns translucent", timeout: 10) { ChromePalette.shared.windowOpacity == 0.8 }
        try await shots("translucent")
        try app.writeConfig(config + "\ntheme = Dracula\n")
        app.runtime.reloadConfig()
        try await app.waitUntil("the chrome follows Dracula again", timeout: 10) {
            ChromePalette.shared.current?.bedrock == 0x282a36 && ChromePalette.shared.windowOpacity == 1
        }

        // The edit clash.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try app.fill("panel-what", with: "A terminal for work that Claude Code does with you.")
        try await app.waitUntil("the Save button for What") { app.exists("panel-save-what") }
        try rig.loam(["set", plot, "what", "A macOS terminal that seeds Claude Code sessions."])
        await app.sleep(1)
        try app.click("panel-save-what")
        try await app.waitUntil("the clash box") { app.exists("panel-clash") }
        for width in [520.0, 260.0] {
            setPanelWidth(host, width)
            await app.sleep(0.8)
            app.screenshot("clash-\(Int(width))")
        }
        try app.click("panel-clash-use-current")
        try await app.waitUntil("the clash closes") { !app.exists("panel-clash") }

        // The missing link callout, the link editor, and the inline add row.
        setPanelWidth(host, 520)
        let links = try rig.show(plot)["links"] as? [[String: Any]] ?? []
        let gone = links.first { ($0["label"] as? String) == "Design pack" }?["id"] as? String ?? ""
        try app.click("panel-link-\(gone)")
        try await app.waitUntil("the missing link callout") { app.exists("panel-missing-link") }
        scrollPanel(host, toEnd: false)
        await app.sleep(0.8)
        app.screenshot("missing-520")
        try app.click("panel-missing-edit-link")
        try await app.waitUntil("the link editor") { app.exists("panel-edit-link-label") }
        await app.sleep(0.8)
        app.screenshot("edit-link-520")
        try app.click("panel-edit-link-cancel")
        try await app.waitUntil("the editor closes") { !app.exists("panel-edit-link-label") }
        try app.click("panel-add-link-open")
        try await app.waitUntil("the add link row") { app.exists("panel-new-link-label") }
        await app.sleep(0.8)
        app.screenshot("add-link-520")
        try app.click("panel-add-cancel")
        try await app.waitUntil("the add row closes") { !app.exists("panel-new-link-label") }
        NSApp.appearance = nil
    }

    /// The split view item that holds the plot panel.
    static func panelItem(_ host: AppHost) -> NSSplitViewItem? {
        (host.window.contentViewController as? NSSplitViewController)?.splitViewItems.last
    }

    /// Drags the panel divider so the panel is `width` points wide.
    static func setPanelWidth(_ host: AppHost, _ width: CGFloat) {
        guard let split = host.window.contentViewController as? NSSplitViewController else { return }
        let view = split.splitView
        view.setPosition(view.bounds.width - width - view.dividerThickness, ofDividerAt: split.splitViewItems.count - 2)
        view.layoutSubtreeIfNeeded()
        Log.line("panel width \(panelItem(host)?.viewController.view.frame.width ?? 0)")
    }

    /// The scroll view of the panel content, if it has one.
    static func panelScrollView(_ host: AppHost) -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        return panelItem(host).flatMap { find($0.viewController.view) }
    }

    /// Scrolls the panel to its top or its end.
    static func scrollPanel(_ host: AppHost, toEnd: Bool) {
        guard let scroll = panelScrollView(host), let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let room = max(0, document.frame.height - clip.bounds.height)
        // The top inset (the toolbar) moves the start of the content, not its end.
        let top = scroll.contentInsets.top
        let y = document.isFlipped ? (toEnd ? room : -top) : (toEnd ? 0 : room)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// A pixel of the panel ground, from a capture of the window: 4 points in from the leading edge
    /// of the panel, at its vertical middle.
    private static func panelGround(_ app: DriverApp, _ host: AppHost) throws -> (Int, Int, Int) {
        guard let view = panelItem(host)?.viewController.view else { throw DriverFailure("no panel view") }
        let point = view.convert(NSPoint(x: 4, y: view.bounds.midY), to: nil)
        let path = "\(app.outFolder)/panel-ground.png"
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", "\(host.window.windowNumber)", path]
        try shot.run()
        shot.waitUntilExit()
        guard let image = NSImage(contentsOfFile: path),
              let rep = image.representations.first as? NSBitmapImageRep
        else { throw DriverFailure("no window capture") }
        let scale = CGFloat(rep.pixelsWide) / host.window.frame.width
        let x = Int(point.x * scale)
        let y = Int((host.window.frame.height - point.y) * scale)
        // The capture holds the window's own values, so no color space conversion.
        guard let color = rep.colorAt(x: x, y: y) else { throw DriverFailure("no pixel") }
        return (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    private static func near(_ pixel: (Int, Int, Int), _ hex: UInt32) -> Bool {
        let want = [Int(hex >> 16) & 0xFF, Int(hex >> 8) & 0xFF, Int(hex) & 0xFF]
        return zip([pixel.0, pixel.1, pixel.2], want).allSatisfy { abs($0 - $1) <= 14 }
    }
}
