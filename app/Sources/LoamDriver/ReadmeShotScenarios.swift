import AppKit
import ImageIO
import LoamKit
import LoamTerminal
import UniformTypeIdentifiers

/// Driver scenario for the README and site shots. It stages the work of a small product team
/// (`ReadmeShotStage`) and takes the shots that `docs/images` and `site/images` hold, at 1440 by
/// 900 points:
///
/// - The pages of runs: Today in Night and Day (`hero-night`, `hero-day`), Intake in Night and Day,
///   a Shape draft at the desk (`desk-shape`), a run's page (`run-page`), Land at the desk with a
///   note on a line (`desk-land`), the Recurring page (`recurring`), and the Runs and Connections
///   tabs of Settings (`settings-runs`, `settings-linear`).
/// - The terminal half: a seeded Claude Code session above a shell with the plot panel open
///   (`session`), the quick switcher (`switcher`), the chrome after a reload with Dracula and with
///   Catppuccin Latte, and the plot panel with a change by Claude (`plot-panel`).
///
/// The runs, Linear, and GitHub are fakes (see `ReadmeShotStage`). The session pane is a real
/// Claude Code session that Loam starts with `loam start`, on the model in
/// `LOAM_CLAUDE_EXTRA_ARGS` (default Haiku). So the scenario needs the network and your Claude Code
/// login, and `DriverTests` does not run it.
///
/// Claude Code and the shells run with a fake HOME in the rig, so they never read or change your
/// own settings. Your login comes from the keychain. Each shot fails the run if a pane shows an
/// email address, the account, or the plan.
///
/// Run (from the repo root):
///
///     go -C core build -o /tmp/loam-readme/bin/loam ./cmd/loam
///     (cd core && go build -o /tmp/loam-readme/bin ./internal/testutil/fakegh ./internal/testutil/fakelinear)
///     LOAM_DRIVER=readme-shots LOAM_DRIVER_OUT=/tmp/loam-readme/out \
///       LOAM_DRIVER_LOAM=/tmp/loam-readme/bin/loam LOAM_DRIVER_FAKE_GH=/tmp/loam-readme/bin/fakegh \
///       LOAM_DRIVER_FAKE_LINEAR=/tmp/loam-readme/bin/fakelinear app/.build/debug/Loam
///
/// `LOAM_DRIVER_CLAUDE` names the claude binary (default: `claude` on PATH). The shots keep the
/// number that the driver gives them: `NN-<name>.png`.
@MainActor
extension Scenarios {
    private static func ensure(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func readmeShots(_ app: DriverApp) async throws {
        defer {
            unsetenv("CFFIXED_USER_HOME")
            NSApp.appearance = nil
        }
        do { try await readmeShotsSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// The first executable `name` on the launch PATH.
    private static func onPath(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The path with every symlink resolved, as Go's `filepath.EvalSymlinks` gives it. Foundation's
    /// `resolvingSymlinksInPath` drops the `/private` of `/private/tmp`.
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `go env` values from your own Go, so the test run in the demo uses your build cache.
    private static func goEnv(_ go: String, _ names: [String]) -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: go)
        process.arguments = ["env"] + names
        // Never a toolchain download: that can stall, and this runs on the main thread.
        process.environment = ProcessInfo.processInfo.environment.merging(["GOTOOLCHAIN": "local"]) { $1 }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        // The read blocks the main thread until `go` ends, which a busy machine can hold for more than 10 s (ticket 131).
        let data = Watchdog.excuse { () -> Data? in
            guard (try? process.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }
        guard let data else { return [:] }
        // One line for each name, empty when the value is empty. Keep the empty lines, so each
        // value stays with its name.
        let values = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return Dictionary(uniqueKeysWithValues: zip(names, values).filter { !$0.1.isEmpty })
    }

    /// The zsh of the demo shells: a short prompt with the folder and the branch, and the folder as
    /// the terminal title.
    private static let demoZshrc = #"""
        setopt prompt_subst
        precmd() {
          branch=$(git branch --show-current 2>/dev/null)
          [[ -n $branch ]] && branch=" %F{green}$branch%f"
          print -Pn "\e]2;%1~\a"
        }
        PROMPT='%F{blue}%1~%f$branch %F{magenta}❯%f '
        """#

    private static func readmeShotsSteps(_ app: DriverApp) async throws {
        let fm = FileManager.default
        let launch = ProcessInfo.processInfo.environment
        let realHome = NSHomeDirectory()
        var rig = try PanelRig(outFolder: app.outFolder)
        // The real Claude Code of this scenario keeps its login and its state in its default places,
        // so it does not get the rig's CLAUDE_CONFIG_DIR. Its `.claude.json` is in the fake HOME.
        rig.environment["CLAUDE_CONFIG_DIR"] = nil
        let home = rig.fakeHome
        let bin = rig.root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)

        // The tools of the demo: loam and claude in the rig's bin, and the folder of your go.
        let claude = launch["LOAM_DRIVER_CLAUDE"] ?? onPath("claude") ?? "\(realHome)/.local/bin/claude"
        try ensure(fm.isExecutableFile(atPath: claude), "no claude binary at \(claude). Set LOAM_DRIVER_CLAUDE")
        try fm.createSymbolicLink(atPath: bin.appendingPathComponent("loam").path, withDestinationPath: rig.binary.path)
        var path = [bin.path]
        var goVariables: [String: String] = [:]
        if let go = onPath("go") {
            path.append((go as NSString).deletingLastPathComponent)
            goVariables = goEnv(go, ["GOCACHE", "GOMODCACHE"])
            goVariables["GOTOOLCHAIN"] = "local"
        }
        path += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

        // The shells: zsh with the demo prompt. libghostty starts each pane through `login -flp`,
        // which sets HOME to your own home folder and prints the last login. So each pane starts
        // through a script that sets HOME to the rig's home again and clears the screen, as a
        // `.hushlogin` would. The shell panes take it from `command`. The session panes take it as
        // the shell that runs `loam start` (`AppModel.shell`).
        let zdot = rig.root.appendingPathComponent("zdot")
        try fm.createDirectory(at: zdot, withIntermediateDirectories: true)
        try demoZshrc.write(to: zdot.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        func script(_ name: String, _ exec: String) throws -> URL {
            let file = rig.root.appendingPathComponent(name)
            try "#!/bin/sh\nexport HOME=\(PaneCommand.quote(home.path))\nprintf '\\033[H\\033[2J\\033[3J'\nexec \(exec)\n"
                .write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file
        }
        let shell = try script("shell.sh", "/bin/zsh -i")
        let sessionShell = try script("session-shell.sh", "/bin/zsh \"$@\"")
        let config = "command = \(shell.path)\n"
        try app.writeConfig(config)
        app.runtime.reloadConfig()

        // Claude Code in the fake HOME: onboarding done, the Loam MCP server, and trust for the plots
        // folder, so the setup banner does not show. The stage adds trust for its repos, which runs need.
        let plots = rig.loamHome.appendingPathComponent("plots").path
        let claudeJSON = home.appendingPathComponent(".claude.json")
        let trusted = Set([plots, realPath(plots)]).reduce(into: [String: Any]()) { $0[$1] = ["hasTrustDialogAccepted": true] }
        let claudeState: [String: Any] = [
            "hasCompletedOnboarding": true,
            "theme": "auto",
            "autoUpdates": false,
            "projects": trusted,
            // The setup check looks for the binary with its symlinks resolved, as `loam` sees itself.
            "mcpServers": ["loam": ["type": "stdio", "command": realPath(rig.binary.path), "args": ["mcp"], "env": [String: String]()]],
        ]
        try JSONSerialization.data(withJSONObject: claudeState, options: [.prettyPrinted]).write(to: claudeJSON)
        try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try #"{"spinnerTipsEnabled": false}"#.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        // Your login is in your login keychain. `security` finds the keychain through HOME, so the
        // fake HOME links to your keychain folder. Nothing is copied.
        let keychains = home.appendingPathComponent("Library/Keychains")
        try fm.createSymbolicLink(atPath: keychains.path, withDestinationPath: "\(realHome)/Library/Keychains")
        // No link to your keychain stays in the out folder after the run.
        defer { try? fm.removeItem(at: keychains) }

        var environment = rig.environment.merging([
            "PATH": path.joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "LESS": "FRX",
            "ZDOTDIR": zdot.path,
            "DISABLE_AUTOUPDATER": "1",
            "LOAM_CLAUDE_EXTRA_ARGS": launch["LOAM_CLAUDE_EXTRA_ARGS"] ?? #"["--model","haiku"]"#,
        ].merging(goVariables) { $1 }) { $1 }

        // The staged work: the repos, the plots, and the runs.
        let stage = try ReadmeShotStage.make(rig: rig, environment: &environment, home: home, bin: bin, claude: claude)
        defer { stage.linear.terminate() }
        let plot = stage.checkout, mobile = stage.mobile

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        let model = host.model
        if app.runtime.onConfigChange == nil {
            app.runtime.onConfigChange = { [weak runtime = app.runtime, weak window = host.window] in
                if let runtime, let window { runtime.applyWindowAppearance(to: window) }
            }
        }
        app.runtime.applyWindowAppearance(to: host.window)
        // The run must not depend on which app you use while it runs, and it posts no real banner.
        model.isFrontmost = { true }
        model.notifier = RecordingNotifier()
        try await app.waitUntil("2 plots") { model.plots.count == 2 && model.workspace.activePlotID != nil && !model.runs.isEmpty }
        try ensure(model.launchBlock == nil, "the launch is blocked: \(model.launchBlock ?? "")")
        try ensure(model.setupSteps.isEmpty, "the setup banner shows: \(model.setupSteps)")
        // The app shows the repo path with a tilde for the home folder. The demo's home is the rig.
        // The panes copied the environment at `ghostty_init`, so they do not get this.
        setenv("CFFIXED_USER_HOME", home.path, 1)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        Log.line("screen \(screen)")
        // The size of the design frames. It can be larger than the screen: the shots capture the whole window.
        host.window.setFrame(NSRect(x: screen.minX, y: screen.maxY - 900, width: 1440, height: 900), display: true)

        func surface(_ pane: PaneID) throws -> TerminalSurfaceView {
            guard let view = host.paneView(pane) as? TerminalSurfaceView else { throw DriverFailure("pane \(pane) has no terminal") }
            return view
        }
        func text(_ pane: PaneID) -> String { (try? surface(pane))?.screenText() ?? "" }
        func focus(_ pane: PaneID) async throws {
            model.goToPane(pane)
            try await app.waitUntil("the pane has the keys") { app.window.firstResponder === (try? surface(pane)) }
        }
        // The waits on the panes (the real Claude Code session, the shell commands, a pane that settles) keep their
        // deadlines, and so do the waits that can never end. The waits on the app itself have none. This scenario is not in
        // the suite: a person runs it with the app in front, and a stuck session would hold the keyboard until the limit
        // of 1200 s.

        /// Waits until the screen of the pane stays the same for `seconds`.
        func settle(_ pane: PaneID, _ seconds: Double = 1.2, timeout: TimeInterval = 30) async throws {
            var last = text(pane)
            var since = Date()
            try await app.waitUntil("the pane settles", timeout: timeout) {
                let now = text(pane)
                if now != last { last = now; since = Date() }
                return Date().timeIntervalSince(since) >= seconds
            }
        }
        func atPrompt(_ pane: PaneID) -> Bool {
            (try? surface(pane)).map { app.lines($0).last { !$0.isEmpty }?.hasSuffix("❯") == true } ?? false
        }
        /// Types a command into a shell and waits for the next prompt.
        func run(_ pane: PaneID, _ command: String, timeout: TimeInterval = 60) async throws {
            try await focus(pane)
            try await app.waitUntil("a shell prompt", timeout: 20) { atPrompt(pane) }
            let before = text(pane)
            try app.type(command)
            app.press(.returnKey)
            try await app.waitUntil("\(command) ran", timeout: timeout) { text(pane) != before && atPrompt(pane) }
            try await settle(pane, 0.5)
        }

        // What no shot may show: an email address, the account, the plan, or your home folder.
        func secrets() -> [String] {
            var words = [realHome, NSUserName(), "Claude Max", "Claude Pro", "Claude Team", "Claude Enterprise"]
            if let data = try? Data(contentsOf: claudeJSON),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let account = object["oauthAccount"] as? [String: Any] {
                words += ["emailAddress", "organizationName", "displayName", "accountUuid", "organizationUuid"]
                    .compactMap { account[$0] as? String }.filter { $0.count >= 3 }
            }
            return words
        }
        let email = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        func masked(_ screenText: String) -> String {
            secrets().reduce(screenText.replacingOccurrences(of: email, with: "<email>", options: .regularExpression)) {
                $0.replacingOccurrences(of: $1, with: "<hidden>", options: .caseInsensitive)
            }
        }
        func dump(_ pane: PaneID, _ label: String) {
            let body = masked(text(pane)).split(separator: "\n", omittingEmptySubsequences: false).map { "    | \($0)" }
            Log.line("SCREEN \(label):\n\(body.joined(separator: "\n"))")
        }
        /// The welcome header (it names the plan) and the notes about your login and your usage.
        let accountNotes = ["Claude Code v", "session limit", "weekly limit", "usage limit", "/upgrade", "/login", "login expires"]
        /// Fails when a pane on screen shows something private.
        func checkPrivate() throws {
            let panes = model.workspace.activeTab?.tree.paneIDs ?? []
            for pane in panes {
                let screenText = text(pane)
                try ensure(screenText.range(of: email, options: .regularExpression) == nil, "a pane shows an email address")
                for word in secrets() where screenText.range(of: word, options: .caseInsensitive) != nil {
                    throw DriverFailure("a pane shows an account detail or a private path")
                }
                for note in accountNotes where screenText.contains(note) {
                    throw DriverFailure("a pane shows \"\(note)\"")
                }
            }
        }
        /// Types a prompt into the session and submits it. Claude Code takes a fast burst of keys
        /// as a paste, and a Return in the paste is a new line. So Return comes after a pause.
        func send(_ pane: PaneID, _ prompt: String) async throws {
            try await focus(pane)
            try app.type(prompt)
            await app.sleep(0.8)
            app.press(.returnKey)
            try await app.waitUntil("claude works", timeout: 30) { model.workspace.state(of: pane) == .working }
        }
        /// Sends a prompt to the session and waits for the end of the turn.
        func ask(_ pane: PaneID, _ prompt: String) async throws {
            try await send(pane, prompt)
            try await app.waitUntil("claude answers", timeout: 180) { model.workspace.state(of: pane) == .idle }
            try await settle(pane, 2)
        }

        // A shell in each other plot. Then in the main checkout of Checkout: a Claude Code session
        // above a shell.
        model.shell = sessionShell.path
        var otherPanes: [PaneID] = []
        for other in [mobile] {
            model.activate(plot: other)
            await model.openShellTab()
            otherPanes += model.workspace.selectedTab(of: .plot(other)).map { [$0.focused] } ?? []
        }
        model.activate(plot: plot)
        model.openTab(.session)
        await model.splitShell(.stacked)
        let mainPanes = model.workspace.tabs(of: .plot(plot)).first?.tree.paneIDs ?? []
        try ensure(mainPanes.count == 2, "the main checkout tab has \(mainPanes.count) panes")
        let claudePane = mainPanes[0], shellPane = mainPanes[1]
        model.setSplitRatio(0.55, at: [])
        // A sidebar wide enough for the names of the run worktrees.
        if let split = host.window.contentViewController as? NSSplitViewController {
            split.splitView.setPosition(265, ofDividerAt: 0)
        }
        // Only the active plot shows its tree. A plot that got its first pane while active can stay
        // open, so close the others with their disclosure arrows.
        await app.sleep(0.5)
        for (other, pane) in zip([mobile], otherPanes) where app.exists("pane-row-\(pane.uuidString)") {
            try ensure(AccessibilityProbe.shared.discloseRow("plot-\(other)", open: false), "the tree of \(other) did not close")
        }
        try await app.waitUntil("the other trees close") { !otherPanes.contains { app.exists("pane-row-\($0.uuidString)") } }

        // The shells.
        try await run(shellPane, "git log --oneline -5")
        try await run(shellPane, "go test ./...", timeout: 180)
        dump(shellPane, "shell")

        // The session: answer the trust question in the pane, then ask about the plot.
        try await focus(claudePane)
        try await app.waitUntil("claude asks for trust or starts", timeout: 90) {
            text(claudePane).localizedCaseInsensitiveContains("trust") || model.workspace.session(of: claudePane)?.started == true
        }
        try await settle(claudePane)
        dump(claudePane, "claude at start")
        if model.workspace.session(of: claudePane)?.started != true {
            // The trust question starts on "No, exit". Move to "Yes, I trust this folder".
            app.press(.down)
            try await app.waitUntil("Yes is selected", timeout: 5) {
                text(claudePane).split(separator: "\n").contains { $0.contains("❯") && $0.contains("Yes") }
            }
            app.press(.returnKey)
        }
        try await app.waitUntil("the session started", timeout: 60) { model.workspace.session(of: claudePane)?.started == true }
        try await settle(claudePane, 2)
        dump(claudePane, "claude ready")
        try ensure(!text(claudePane).contains("Not logged in"), "Claude Code is not logged in with the fake HOME")
        // Two turns. The welcome header names your plan, and neither /clear nor Control-L removes
        // it. The two answers push it off the top of the pane.
        try await ask(claudePane, "From the plot brief you were given, list the link labels, one per line.")
        dump(claudePane, "claude read the plot")
        try await ask(claudePane, "In two sentences: what is this plot and what is next?")
        dump(claudePane, "claude answered")

        /// A single theme stays dark in Day, so the wait for the pane can never end. It keeps its deadline, and the run goes on.
        func appearance(_ name: NSAppearance.Name) async {
            NSApp.appearance = NSAppearance(named: name)
            try? await app.waitUntil("the pane follows \(name.rawValue)", timeout: 10) {
                guard let view = try? surface(shellPane), let pixel = app.backgroundPixel(view) else { return false }
                return (pixel.0 + pixel.1 + pixel.2 < 3 * 128) == (name == .darkAqua)
            }
            try? await settle(claudePane, 1.5)
        }
        /// A shot of the window as the active window, so it has its colored window buttons. Then
        /// the app you used before is active again.
        /// With `panel`, the shot keeps only the plot panel.
        /// With `of`, the shot is of that window, such as the settings window.
        func shot(_ name: String, panel: Bool = false, of other: NSWindow? = nil) async throws {
            try checkPrivate()
            let previous = NSWorkspace.shared.frontmostApplication
            NSApp.activate()
            let window = other ?? host.window
            window.makeKeyAndOrderFront(nil)
            // These three waits can fail to end (the app stays inactive, an image stays on the clipboard), so they keep their
            // deadlines and the shot goes on.
            try? await app.waitUntil("the window is active", timeout: 2) { NSApp.isActive && window.isKeyWindow }
            // When the pane gets the focus, Claude Code can show a short note about an image on
            // your clipboard. Wait for the note to go.
            try? await settle(claudePane, 1, timeout: 5)
            try? await app.waitUntil("no clipboard note", timeout: 10) { !text(claudePane).contains("Image in clipboard") }
            if panel { try cropToPanel(app, host, name) } else { app.screenshot(name, of: other) }
            if let previous, previous != NSRunningApplication.current { previous.activate() }
        }
        // The pages of runs.
        try await runPages(app, host, stage, shot: { try await shot($0) }, window: { try await shot($0, of: $1) })

        // The terminal half: the panel open, the session focused.
        model.closePage()
        try await app.waitUntil("the panes show") { model.page == nil && !app.exists("today") }
        try await app.openPanel(host)
        // The panel opens with an animation, and a width set before its end does not hold.
        await app.sleep(0.6)
        setPanelWidth(host, 320)
        scrollPanel(host, toEnd: false)
        try await focus(claudePane)
        await appearance(.darkAqua)
        try await shot("session")

        // The quick switcher, with a query.
        await appearance(.darkAqua)
        try app.pressMenuKey("p")
        try await app.waitUntil("the switcher shows") { app.exists("switcher-field") }
        try await app.waitUntil("the field has the keys") { (app.window.firstResponder as? NSTextView)?.isFieldEditor == true }
        try app.type("pay")
        try await app.waitUntil("the switcher lists matches") { app.exists("switcher-row-1") }
        await app.sleep(0.8)
        try await shot("switcher")
        app.press(.escape)
        try await app.waitUntil("the switcher closes") { !app.exists("switcher-field") }

        // The chrome follows a Ghostty theme from a config reload: a dark one and a light one.
        for (theme, background) in [("Dracula", UInt32(0x282a36)), ("Catppuccin Latte", UInt32(0xeff1f5))] {
            try app.writeConfig(config + "theme = \(theme)\n")
            app.runtime.reloadConfig()
            try await app.waitUntil("the chrome follows \(theme)") { ChromePalette.shared.current?.bedrock == background }
            try await settle(claudePane, 1.5)
            try await shot("theme-" + theme.lowercased().replacingOccurrences(of: " ", with: "-"))
        }
        try app.writeConfig(config)
        app.runtime.reloadConfig()
        await appearance(.darkAqua)

        // Claude writes the plot. A session in auto mode does not ask. One that asks (a first call to get the plot,
        // then the write) gets Return for each question until the change shows. Return goes only while a question
        // shows, so a late Return never answers something else.
        try await send(claudePane, "Call the mcp__loam__set_where_it_stands tool yourself, not through an agent, "
            + "for this plot with the text: \"Webhook retries are ready to land. Next: the gift card VAT fix.\"")
        try await focus(claudePane)
        let deadline = Date().addingTimeInterval(180)
        while !app.exists("panel-new-since") && Date() < deadline {
            await app.sleep(1)
            if text(claudePane).contains("Do you want to proceed?") { app.press(.returnKey); await app.sleep(2) }
        }
        try ensure(app.exists("panel-new-since"), "the change by Claude did not show as new")
        try await app.waitUntil("claude is done", timeout: 120) { model.workspace.state(of: claudePane) == .idle }
        try await settle(claudePane, 1.5)
        dump(claudePane, "claude done")
        setPanelWidth(host, 360)
        scrollPanel(host, toEnd: false)
        await app.sleep(1)
        try await shot("plot-panel", panel: true)
    }

    /// Captures the window and keeps the plot panel: from its leading edge to the window's trailing
    /// edge, at full height. It writes `<name>.png` in the out folder.
    private static func cropToPanel(_ app: DriverApp, _ host: AppHost, _ name: String) throws {
        guard let panel = panelItem(host)?.viewController.view else { throw DriverFailure("no panel view") }
        let full = "\(app.outFolder)/\(name)-window.png"
        // A capture from an earlier run must never stand in for this one.
        try? FileManager.default.removeItem(atPath: full)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(host.window.windowNumber)", full]
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0 else { throw DriverFailure("screencapture exited \(capture.terminationStatus)") }
        guard let sourceImage = CGImageSourceCreateWithURL(URL(fileURLWithPath: full) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(sourceImage, 0, nil)
        else { throw DriverFailure("no window capture") }
        let scale = CGFloat(image.width) / host.window.frame.width
        let left = panel.convert(NSPoint(x: 0, y: 0), to: nil).x
        let rect = CGRect(x: (left * scale).rounded(), y: 0, width: CGFloat(image.width) - (left * scale).rounded(), height: CGFloat(image.height))
        guard let cropped = image.cropping(to: rect) else { throw DriverFailure("the crop failed") }
        let out = URL(fileURLWithPath: "\(app.outFolder)/\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw DriverFailure("no PNG writer") }
        CGImageDestinationAddImage(destination, cropped, nil)
        guard CGImageDestinationFinalize(destination) else { throw DriverFailure("the PNG write failed") }
        Log.line("screenshot \(out.path) (the panel)")
    }
}
