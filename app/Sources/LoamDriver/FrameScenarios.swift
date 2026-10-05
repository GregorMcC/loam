import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 68: the main window with terminal panes, in Night and Day, for
/// screenshots next to other terminal apps. With `XDG_CONFIG_HOME` set, the run takes the Ghostty
/// config in `$XDG_CONFIG_HOME/ghostty/config` (use a temp copy, never your own folder). Without
/// it, the panes use Loam's own themes.
@MainActor
extension Scenarios {
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func frameShot(_ app: DriverApp) async throws {
        do { try await frameShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// Runs git in a folder with no global config, so the host's signing and hooks do not matter.
    /// It waits for the exit with a termination handler, so the main thread never blocks.
    static func runGit(_ folder: URL, _ args: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Driver", "-c", "user.email=driver@example.com",
                             "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
        process.currentDirectoryURL = folder
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": folder.path,
                               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
        if status != 0 { throw DriverFailure("git \(args.joined(separator: " ")) failed in \(folder.path)") }
    }

    /// Each pane prints a short screen with the ANSI colors, so the theme shows, then waits.
    private static let demoScript = #"""
        #!/bin/sh
        runs="RUNS_FOLDER"
        mkdir -p "$runs"
        n=$(ls "$runs" | wc -l | tr -d ' ')
        touch "$runs/$$"
        p() { printf "$@"; }
        prompt() { p '\033[34m~/Development/loam\033[0m \033[32mmain\033[0m \033[35m>\033[0m %s\n' "$1"; }
        case $((n % 3)) in
        0)
          prompt 'git log --oneline -4'
          p '\033[33m34c6ada5\033[0m Ticket 68: native frame and theme chrome prototype\n'
          p '\033[33m76220ea8\033[0m Bug 66: panes and loam calls get login-shell PATH\n'
          p '\033[33mf523dad6\033[0m MCP writes reach the app\n'
          p '\033[33m8bf4598d\033[0m Bugs 66 and 67\n\n'
          prompt 'swift test --filter ChromePalette'
          p '[1/3] Compiling LoamKit ChromePalette.swift\n'
          p '\033[32m✔\033[0m Test run with 12 tests passed after 0.04 seconds.\n\n'
          prompt '' ;;
        1)
          prompt 'ls'
          p '\033[1;34mapp\033[0m  \033[1;34mcontract\033[0m  \033[1;34mcore\033[0m  \033[1;34mdocs\033[0m  \033[1;34mscripts\033[0m  CONTEXT.md  README.md\n\n'
          prompt 'git status --short'
          p ' \033[31mM\033[0m app/Sources/Loam/MainWindowController.swift\n'
          p ' \033[31mM\033[0m app/Sources/Loam/SidebarView.swift\n'
          p '\033[32m??\033[0m app/Sources/LoamKit/Theme/ChromePalette.swift\n\n'
          prompt '' ;;
        *)
          prompt 'go test ./...'
          p '\033[32mok\033[0m  \tloam/internal/store\t0.412s\n'
          p '\033[32mok\033[0m  \tloam/internal/worktree\t1.208s\n'
          p '\033[31m--- FAIL\033[0m: TestUndoClash (0.01s)\n'
          p '\033[36m    undo_test.go:88\033[0m: want "old", got "new"\n\n'
          prompt '' ;;
        esac
        exec sleep 600
        """#

    /// The setup of a shot run, as on a Mac in use: the demo panes, the config under test, a fake
    /// `claude` that reports the MCP server, and trust for the plots folder. So the setup banner does
    /// not show in the shots. `config` is the Ghostty config that the run wrote.
    static func shotRig(_ app: DriverApp) throws -> (rig: PanelRig, environment: [String: String], config: String) {
        let fm = FileManager.default
        let demo = "\(app.outFolder)/demo.sh"
        // libghostty keeps the environment of the launch, so the script holds its folder.
        try demoScript.replacingOccurrences(of: "RUNS_FOLDER", with: "\(app.outFolder)/demo-runs")
            .write(toFile: demo, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: demo)

        // The config under test, from a temp XDG_CONFIG_HOME. Ghostty finds its themes there too.
        // `LOAM_DRIVER_GHOSTTY_CONFIG` names a config file instead (give its themes as absolute paths).
        var config = "command = \(demo)\n"
        let launchEnvironment = ProcessInfo.processInfo.environment
        if let file = launchEnvironment["LOAM_DRIVER_GHOSTTY_CONFIG"] ?? launchEnvironment["XDG_CONFIG_HOME"].map({ "\($0)/ghostty/config" }),
           let text = try? String(contentsOfFile: file, encoding: .utf8) {
            config += text
        }
        try app.writeConfig(config)
        app.runtime.reloadConfig()

        let rig = try PanelRig(outFolder: app.outFolder)
        let bin = rig.root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        let names = [rig.binary.path, rig.binary.resolvingSymlinksInPath().path, "/private" + rig.binary.path]
        try "#!/bin/sh\necho \"loam: \(names.joined(separator: " ")) mcp\"\n".write(to: claude, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let plots = rig.loamHome.appendingPathComponent("plots").path
        let trusted = [plots, plots.replacingOccurrences(of: "/tmp/", with: "/private/tmp/")]
            .map { "\"\($0)\": {\"hasTrustDialogAccepted\": true}" }.joined(separator: ", ")
        try fm.createDirectory(at: rig.fakeHome, withIntermediateDirectories: true)
        try "{\"projects\": {\(trusted)}}".write(to: rig.fakeHome.appendingPathComponent(".claude.json"),
                                                  atomically: true, encoding: .utf8)
        let environment = rig.environment.merging([
            "PATH": bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
        ]) { $1 }
        return (rig, environment, config)
    }

    private static func frameShotSteps(_ app: DriverApp) async throws {
        let fm = FileManager.default
        let (rig, environment, extra) = try shotRig(app)

        let plot = try rig.newPlot("Loam v1 build")
        // A main repo on branch main, for the window subtitle. It is a real repo with a commit, so a
        // worktree can start from main (ticket 71).
        let repo = rig.root.appendingPathComponent("loam")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try "loam\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await runGit(repo, ["init", "-q"])
        try await runGit(repo, ["add", "."])
        try await runGit(repo, ["commit", "-q", "-m", "first"])
        try rig.loam(["repo", "add", plot, repo.path])
        try rig.loam(["set", plot, "what", "A macOS terminal on libghostty that seeds Claude Code sessions."])
        // One link of each kind, for the icons in the panel and the switcher.
        try rig.loam(["link", "add", plot, "loam on GitHub", "https://github.com/GregorMcC/loam"])
        try rig.loam(["link", "add", plot, "Redesign project", "https://linear.app/loam/project/redesign"])
        try rig.loam(["link", "add", plot, "Launch plan", "https://www.notion.so/loam/Launch-plan-0123456789abcdef0123456789abcdef"])
        try rig.loam(["link", "add", plot, "Design chat", "https://claude.ai/chat/0123"])
        try rig.loam(["link", "add", plot, "Ghostty docs", "https://ghostty.org/docs"])
        try rig.loam(["link", "add", plot, "Repo folder", repo.path])
        _ = try rig.newPlot("Client onboarding")
        _ = try rig.newPlot("Release notes")


        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        // The window follows the Ghostty config as in the app. A build that does not wire it in the
        // host gets the same wiring here, so the scenario also runs on older code for a before shot.
        if app.runtime.onConfigChange == nil {
            app.runtime.onConfigChange = { [weak runtime = app.runtime, weak window = host.window] in
                if let runtime, let window { runtime.applyWindowAppearance(to: window) }
            }
        }
        app.runtime.applyWindowAppearance(to: host.window)
        try await app.waitUntil("a plot is active") { host.model.workspace.activePlotID != nil }
        // Ticket 71: a worktree off main. The plot then holds the main checkout with a split tab of 2
        // panes, and the worktree with a tab of 1 pane.
        let made = try await host.model.client.worktreeNew(plot: plot, repo: repo.path, name: "fix-login", base: "main")
        await host.model.reloadWorktrees()
        host.model.activate(number: 1)
        host.model.openTab()
        host.model.split(.sideBySide)
        host.model.openWorktreePane(made.worktree, kind: .shell)
        host.model.activate(number: 2)
        host.model.openTab()
        host.model.activate(number: 1)
        host.model.selectTab(number: 1)
        try await app.waitUntil("4 demo panes ran", timeout: 15) {
            ((try? fm.contentsOfDirectory(atPath: "\(app.outFolder)/demo-runs"))?.count ?? 0) >= 4
        }
        let tabs = host.model.workspace.tabs(of: plot)
        let mainPanes = tabs.first?.tree.paneIDs ?? []
        let worktreePane = try tabs.last?.focused ?? { throw DriverFailure("no worktree tab") }()
        try await app.waitUntil("the main checkout row") { app.text(of: "main-checkout-\(plot)")?.contains("main") == true }
        try await app.waitUntil("the worktree row") { app.exists("worktree-\(made.worktree.id)") }
        // The split tab groups its panes under a tab row in the main checkout.
        let splitTab = "tab-row-\(tabs.first?.id.uuidString ?? "")"
        try check(app.treeParent(of: splitTab) == "main-checkout-\(plot)",
                  "the split tab row sits under \(app.treeParent(of: splitTab) ?? "nothing")")
        for pane in mainPanes {
            try check(app.treeParent(of: "pane-row-\(pane.uuidString)") == splitTab,
                      "a split tab pane sits under \(app.treeParent(of: "pane-row-\(pane.uuidString)") ?? "nothing")")
        }
        try check(app.treeParent(of: "pane-row-\(worktreePane.uuidString)") == "worktree-\(made.worktree.id)",
                  "the worktree pane sits under \(app.treeParent(of: "pane-row-\(worktreePane.uuidString)") ?? "nothing")")
        // Ticket 92: the worktree row nests under the row of its repo.
        try check(app.treeParent(of: "worktree-\(made.worktree.id)") == "main-checkout-\(plot)",
                  "the worktree row sits under \(app.treeParent(of: "worktree-\(made.worktree.id)") ?? "nothing")")
        // A Claude session tab, so the tree shows the Claude mark beside the shells.
        host.model.openTab(.session)
        host.model.selectTab(number: 1)
        if host.window.toolbar != nil {
            try await app.waitUntil("the subtitle") { !host.window.subtitle.isEmpty }
            try check(host.window.subtitle == "loam \u{00B7} main", "the subtitle is \(host.window.subtitle)")
            // Ticket 69: a branch switch in a pane moves HEAD, and the subtitle follows. Git writes a
            // lock file and renames it over HEAD, as this does. Ticket 71: the main checkout row follows too.
            try "ref: refs/heads/feature\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
            try await app.waitUntil("the subtitle follows HEAD", timeout: 5) { host.window.subtitle == "loam \u{00B7} feature" }
            try await app.waitUntil("the main checkout row follows HEAD", timeout: 5) {
                app.text(of: "main-checkout-\(plot)")?.contains("feature") == true
            }
            try "ref: refs/heads/main\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
            try await app.waitUntil("the subtitle goes back", timeout: 5) { host.window.subtitle == "loam \u{00B7} main" }
            try await app.waitUntil("the main checkout row goes back", timeout: 5) {
                app.text(of: "main-checkout-\(plot)")?.contains("main") == true
            }
        }

        /// The focused pane's background, read from the surface libghostty presents.
        func panePixel() -> (Int, Int, Int)? {
            let pane = host.model.workspace.selectedTab(of: host.model.workspace.activePlotID ?? "")?.focused
            return pane.flatMap { host.paneView($0) as? TerminalSurfaceView }.flatMap(app.backgroundPixel)
        }
        /// A shot once the panes and the window agree on Night or Day. The window takes its
        /// appearance from the terminal background (`window-theme = auto`), after the chrome.
        func shot(_ name: String, _ appearance: NSAppearance.Name) async throws {
            NSApp.appearance = NSAppearance(named: appearance)
            // A single theme (no dark: and light: pair) stays dark in Day, so a timeout does not fail the run.
            try? await app.waitUntil("\(name): the panes and the window agree", timeout: 10) {
                guard let pixel = panePixel() else { return false }
                let darkPane = pixel.0 + pixel.1 + pixel.2 < 3 * 128
                let darkWindow = host.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return darkPane == darkWindow && darkWindow == (appearance == .darkAqua)
            }
            await app.sleep(1)
            Log.line("RESULT \(name): pane \(panePixel().map { "\($0)" } ?? "?"), window key \(host.window.isKeyWindow)")
            app.screenshot(name)
        }
        /// Ticket 90: the switcher with its preview, for a plot, a pane, and a link. The plot preview
        /// waits for its link count, which comes with the one `loam export`.
        func previewShots(_ name: String) async throws {
            // The switcher spans the well and the plot panel, so the preview shows with the panel open.
            try app.pressMenuKey("p")
            try await app.waitUntil("\(name): the switcher shows", timeout: 5) { app.exists("switcher-field") }
            try app.fill("switcher-field", with: "loam v1")
            try await app.waitUntil("\(name): the plot preview", timeout: 10) {
                app.text(of: "switcher-preview-title") == "Loam v1 build"
                    && app.text(of: "switcher-preview-caption")?.hasSuffix("links") == true
            }
            await app.sleep(0.6)
            app.screenshot("\(name)-switcher-preview-plot")
            try app.fill("switcher-field", with: "shell")
            try await app.waitUntil("\(name): the pane preview", timeout: 5) {
                app.text(of: "switcher-preview-caption")?.hasPrefix("Pane") == true
            }
            await app.sleep(0.4)
            app.screenshot("\(name)-switcher-preview-pane")
            try app.fill("switcher-field", with: "github")
            try await app.waitUntil("\(name): the link preview", timeout: 5) {
                app.text(of: "switcher-preview-caption") == "GitHub link"
            }
            await app.sleep(0.4)
            app.screenshot("\(name)-switcher-preview-link")
            app.press(.escape)
            try await app.waitUntil("\(name): the switcher closes", timeout: 5) { !app.exists("switcher-field") }
        }

        try await shot("night", .darkAqua)
        try await shot("day", .aqua)
        // Ticket 71: the worktree tab holds 1 pane, so the pane has no header (its state words are
        // gone). The split tab has a header on each pane.
        for pane in mainPanes {
            try check(app.exists("pane-state-\(pane.uuidString)"), "a pane in the split tab has no header")
        }
        // Selecting the pane row in the sidebar goes to the pane.
        try app.selectRow("pane-row-\(worktreePane.uuidString)")
        try await app.waitUntil("the worktree tab shows") { host.model.workspace.focusedPane == worktreePane }
        await app.sleep(0.3)  // A fresh scan of the accessibility tree, with the tab on screen.
        try check(app.exists("pane-ring-\(worktreePane.uuidString)"), "the worktree pane is not on screen")
        try check(!app.exists("pane-state-\(worktreePane.uuidString)"), "the pane alone in its tab has a header")
        try await shot("night-one-pane", .darkAqua)
        // Selecting another plot makes it active. Its tree opens and the tree of the plot you left closes.
        let other = try host.model.sidebar.plotID(forNumber: 2) ?? { throw DriverFailure("no second plot") }()
        let otherPane = try host.model.workspace.tabs(of: other).first?.focused ?? { throw DriverFailure("no pane in \(other)") }()
        try app.selectRow("plot-\(other)")
        try await app.waitUntil("the other plot is active") { host.model.workspace.activePlotID == other }
        try await app.waitUntil("its tree opens and the old one closes") {
            app.exists("pane-row-\(otherPane.uuidString)") && !app.exists("pane-row-\(worktreePane.uuidString)")
        }
        try app.selectRow("plot-\(plot)")
        try await app.waitUntil("the first plot is active again") { host.model.workspace.activePlotID == plot }
        // A press on the main checkout row goes to its first pane.
        try await app.waitUntil("the tree opens again") { app.exists("main-checkout-\(plot)") }
        try app.click("main-checkout-\(plot)")
        try await app.waitUntil("the main checkout pane has focus") { host.model.workspace.focusedPane == mainPanes.first }
        host.model.selectTab(number: 1)
        // The plot panel stands on horizon-a, which follows the terminal too.
        try await app.openPanel(host)
        try await shot("night-panel", .darkAqua)

        // The quick switcher, in the style of Spotlight: recent items in sections, then a query.
        for (name, appearance) in [("night", NSAppearance.Name.darkAqua), ("day", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            try app.pressMenuKey("p")
            try await app.waitUntil("the switcher shows", timeout: 5) { app.exists("switcher-field") }
            try await app.waitUntil("the switcher lists panes", timeout: 5) { app.exists("switcher-row-2") }
            await app.sleep(0.8)
            app.screenshot("\(name)-switcher")
            // Links show only after you type. They load with one `loam export`.
            try app.type("lo")
            try await app.waitUntil("the switcher lists the links", timeout: 10) {
                host.model.switcher.results.contains { $0.item.kind == .link }
            }
            await app.sleep(0.8)
            app.screenshot("\(name)-switcher-query")
            app.press(.escape)
            try await app.waitUntil("the switcher closes", timeout: 5) { !app.exists("switcher-field") }
            try await previewShots(name)
        }

        // A config reload with another theme: the chrome follows it at once.
        try app.writeConfig(extra + "\ntheme = Dracula\n")
        app.runtime.reloadConfig()
        try await app.waitUntil("the chrome follows Dracula (#282a36)", timeout: 10) {
            ChromePalette.shared.current?.bedrock == 0x282a36
        }
        try check(ChromePalette.shared.current?.horizonO == ChromeSurfaces.derive(background: 0x282a36).horizonO,
                  "the chrome did not derive from the new background")
        try await shot("night-reload", .darkAqua)

        // Ghostty's `background-opacity` below 1: the window turns translucent, and the grounds behind
        // the panes clear, so the desktop shows through. Back at 1 the window is solid again.
        try app.writeConfig(extra + "\ntheme = Dracula\nbackground-opacity = 0.8\nbackground-blur = 20\n")
        app.runtime.reloadConfig()
        try await app.waitUntil("the window turns translucent", timeout: 10) {
            ChromePalette.shared.isTranslucent && !host.window.isOpaque
        }
        try check(ChromePalette.shared.windowOpacity == 0.8, "the palette opacity is \(ChromePalette.shared.windowOpacity)")
        try await shot("night-translucent", .darkAqua)
        try await previewShots("night-translucent")
        // Ticket 88: with no blur the shot keeps the window alpha, so the edges of the well can be
        // measured. Every edge pixel must read the window alpha, with no clear line.
        try app.writeConfig(extra + "\ntheme = Dracula\nbackground-opacity = 0.8\n")
        app.runtime.reloadConfig()
        await app.sleep(1)
        try await shot("night-translucent-clear", .darkAqua)
        try app.writeConfig(extra + "\ntheme = Dracula\n")
        app.runtime.reloadConfig()
        try await app.waitUntil("the window turns solid again", timeout: 10) {
            !ChromePalette.shared.isTranslucent && host.window.isOpaque
        }

        // A third-party theme: Catppuccin Mocha (#1e1e2e). The switcher takes its surfaces from it.
        try app.writeConfig(extra + "\ntheme = Catppuccin Mocha\n")
        app.runtime.reloadConfig()
        try await app.waitUntil("the chrome follows Catppuccin Mocha (#1e1e2e)", timeout: 10) {
            ChromePalette.shared.current?.bedrock == 0x1e1e2e
        }
        await app.sleep(1)
        try await previewShots("catppuccin")
        try app.writeConfig(extra + "\ntheme = Dracula\n")
        app.runtime.reloadConfig()

        // Ticket 63: with the sidebar hidden, the window buttons sit in the toolbar, over no tab.
        try app.pressMenuKey("i")
        try app.pressMenuKey("b")
        try await app.waitUntil("the sidebar hides") { host.model.sidebarCollapsed }
        try await shot("night-no-sidebar", .darkAqua)
        NSApp.appearance = nil
    }
}
