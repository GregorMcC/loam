import Foundation
import Testing

/// Runs the built app in driver mode, one scenario per test, and checks the log.
/// The app opens a window for a few seconds. The panes run `zsh -f` or
/// `bash --noprofile --norc`, so the tests cost no usage.
/// Set LOAM_SKIP_DRIVER=1 to skip them.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LOAM_SKIP_DRIVER"] == nil))
struct DriverTests {
    /// The debug Loam binary that `swift test` builds, or LOAM_APP_BINARY.
    static var appBinary: URL {
        if let path = ProcessInfo.processInfo.environment["LOAM_APP_BINARY"] { return URL(fileURLWithPath: path) }
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.appendingPathComponent(".build/debug/Loam")
    }

    struct Run {
        let exitCode: Int32
        let log: String
    }

    func drive(_ scenario: String, environment extra: [String: String] = [:]) async throws -> Run {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("loam-driver-\(scenario)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = Self.appBinary
        var environment = ProcessInfo.processInfo.environment
        environment["LOAM_DRIVER"] = scenario
        environment["LOAM_DRIVER_OUT"] = out.path
        environment.merge(extra) { _, new in new }
        process.environment = environment
        process.standardError = FileHandle.nullDevice
        // No waitUntilExit: it can wait forever on a process that already exited.
        let exit = ExitBox()
        process.terminationHandler = { exit.set($0.terminationStatus) }
        try process.run()
        // The driver has its own limits. This one catches a stuck launch.
        var deadline = Date().addingTimeInterval(60)
        while exit.status == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if exit.status == nil {
            kill(process.processIdentifier, SIGKILL)
            deadline = Date().addingTimeInterval(5)
            while exit.status == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        }
        let log = (try? String(contentsOf: out.appendingPathComponent("driver.log"), encoding: .utf8)) ?? ""
        return Run(exitCode: exit.status ?? -1, log: log)
    }

    /// The exit status from the termination handler, which runs on another thread.
    final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32?
        var status: Int32? { lock.withLock { value } }
        func set(_ status: Int32) { lock.withLock { value = status } }
    }

    func expectPass(_ scenario: String, environment: [String: String] = [:]) async throws {
        let run = try await drive(scenario, environment: environment)
        #expect(run.exitCode == 0, "exit \(run.exitCode)\n\(run.log)")
        #expect(run.log.contains("PASS \(scenario)"), "\(run.log)")
    }

    @Test func typesIntoAShellWithAComposedCharacter() async throws { try await expectPass("type") }
    @Test func pastesAndAsksBeforeAnUnsafePaste() async throws { try await expectPass("paste") }
    @Test func selectsAndCopies() async throws { try await expectPass("select-copy") }
    @Test func scrollsWithMomentum() async throws { try await expectPass("scroll") }
    @Test func resizesTheGridAndThePTY() async throws { try await expectPass("resize") }
    @Test func closesTwoStreamingPanesWithNoHang() async throws { try await expectPass("close-streaming") }

    @Test func closesTheTitleSpamPaneOfIssue14245() async throws {
        let run = try await drive("spam")
        #expect(run.exitCode == 0, "exit \(run.exitCode) (3 is a hang)\n\(run.log)")
        #expect(run.log.contains("RESULT spam safe close returned"), "\(run.log)")
    }

    @Test func givesThePaneACleanEnvironment() async throws {
        try await expectPass("env", environment: [
            "CLAUDECODE": "1",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "SUPACODE_SURFACE_ID": "leak",
            "GHOSTTY_RESOURCES_DIR": "/loam-test-leak",
            "TERMINFO": "/loam-test-leak",
        ])
    }

    /// Ticket 59: a pane gets only Loam's GHOSTTY_RESOURCES_DIR, themes, terminfo, and shell integration
    /// still work, and the window title stays hidden.
    @Test func panesGetLoamsResourcesAndTheTitleStaysHidden() async throws {
        try await expectPass("pane-resources", environment: ["GHOSTTY_RESOURCES_DIR": "/loam-test-leak"])
    }

    /// The `loam` binary for the panel scenarios: LOAM_DRIVER_LOAM, else a build of ../core in a temp folder.
    static let loamBinary: String = {
        if let path = ProcessInfo.processInfo.environment["LOAM_DRIVER_LOAM"] { return path }
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("core")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("loam-driver-core-\(UUID().uuidString)")
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["go", "build", "-o", out.path, "./cmd/loam"]
        build.currentDirectoryURL = core
        do { try build.run() } catch { fatalError("go build did not start: \(error)") }
        build.waitUntilExit()
        if build.terminationStatus != 0 { fatalError("go build ../core failed with \(build.terminationStatus)") }
        return out.path
    }()

    /// Ticket 35 and 37: edit the brief, add a link, open a vault link, a missing link, an edit clash.
    @Test func editsThePlotInThePanel() async throws {
        try await expectPass("panel-edit", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// Ticket 81: ⌘, opens Settings, the repo folders come from the settings file, and a hand edit applies.
    @Test func opensSettingsAndFollowsTheFile() async throws {
        try await expectPass("settings", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// Ticket 36 and 37: a change by Claude shows as new, Undo reverts it, the clash, seen, the sidebar count.
    @Test func reviewsAndUndoesAChangeByClaude() async throws {
        try await expectPass("panel-review", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// The core's fake `claude` in hook mode, built from ../core: LOAM_DRIVER_FAKE_CLAUDE, else a build in a temp folder.
    static let fakeClaude: String = {
        if let path = ProcessInfo.processInfo.environment["LOAM_DRIVER_FAKE_CLAUDE"] { return path }
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("core")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("loam-driver-fakeclaude-\(UUID().uuidString)")
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["go", "build", "-o", out.path, "./internal/testutil/fakeclaude"]
        build.currentDirectoryURL = core
        do { try build.run() } catch { fatalError("go build did not start: \(error)") }
        build.waitUntilExit()
        if build.terminationStatus != 0 { fatalError("go build of the fake claude failed with \(build.terminationStatus)") }
        return out.path
    }()

    /// Ticket 28: a seeded pane and a shell pane, the pane socket, /clear, and "Session ended" with resume, new, and close.
    @Test func runsSeededAndShellPanesAndShowsSessionEnded() async throws {
        try await expectPass("panes", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude,
        ])
    }

    /// Ticket 41: a worktree, a pane in it with its branch in the header, the setup question, a refused removal,
    /// and "Session ended" for a worktree that is gone.
    @Test func runsAPaneInAWorktreeAndRefusesToRemoveItWhileOpen() async throws {
        try await expectPass("worktrees", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude,
        ])
    }

    /// Ticket 48: archive a plot with a session, unarchive it and see the session resume, and delete an archived plot.
    /// Ticket 61: an unarchive and show at once still gives one `claude` for the session.
    @Test func archivesUnarchivesAndDeletesAPlot() async throws {
        try await expectPass("archive", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude,
        ])
    }

    /// Ticket 29: quit with 2 plots of panes (a mid-turn session makes quit ask), relaunch on the
    /// same temp store and `state.json`, show each plot, and see each session resume.
    @Test func restoresThePanesAfterAQuit() async throws {
        let rig = FileManager.default.temporaryDirectory.appendingPathComponent("loam-driver-restore-\(UUID().uuidString)")
        let environment = [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude, "LOAM_DRIVER_RIG": rig.path,
        ]
        try await expectPass("restore-quit", environment: environment)
        try await expectPass("restore-relaunch", environment: environment)
    }

    /// Ticket 32: 3 plots, a permission prompt in a plot that is not active shows on its sidebar row,
    /// ⌘L reaches it, and a key clears it. Also done, unread, the banner, the title bar button, and Reduce Motion.
    @Test func showsAPaneThatNeedsYouAndReachesItWithCommandL() async throws {
        try await expectPass("attention", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude,
        ])
    }

    /// Ticket 96: hover a tab that is not selected and click its `x`: the tab goes and the selection stays.
    /// The `x` of a tab with a session that is mid-turn shows the close question first.
    @Test func closesATabFromItsHoverClose() async throws {
        try await expectPass("tab-close", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude,
        ])
    }

    @Test func reloadsTheConfigAndRedrawsThePane() async throws { try await expectPass("config-reload") }
    @Test func routesGhosttyActionsAndLoamKeys() async throws { try await expectPass("keys") }
    /// Ticket 38: ⌘P and a few keys reach a pane, a plot, a link, and a menu action.
    @Test func switchesWithTheQuickSwitcher() async throws {
        try await expectPass("switcher", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// Ticket 55: Loam Night and Day load by default, and your own theme wins.
    @Test func loadsTheLoamThemesAndLetsYourThemeWin() async throws { try await expectPass("theme") }

    /// Ticket 55: the main window in Night and Day, with the tab bar and the panel.
    @Test func showsTheMainWindowInNightAndDay() async throws {
        try await expectPass("window-shot", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// Ticket 68: the native frame with terminal panes, and the chrome follows a theme from a config
    /// reload. No XDG_CONFIG_HOME config, so the run never reads your Ghostty config.
    @Test func theChromeFollowsTheTerminalTheme() async throws {
        try await expectPass("frame-shot", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "XDG_CONFIG_HOME": "/nonexistent-loam-driver-xdg",
        ])
    }

    /// Ticket 86: the sidebar search button and attention rows in Night, Day, Catppuccin Mocha, and
    /// translucent. A click on each attention row cycles through the panes in its state.
    @Test func showsTheSidebarSearchAndAttentionRows() async throws {
        try await expectPass("sidebar-shot", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// Ticket 89: the action bar with a toast, and the actions menu: ⌘J opens and closes it, a
    /// filter and Return run Split down, and Add link opens the panel row. Night, Day, and Catppuccin Mocha.
    @Test func runsAnActionFromTheActionsMenu() async throws {
        try await expectPass("actions", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "XDG_CONFIG_HOME": "/nonexistent-loam-driver-xdg",
        ])
    }

    /// Ticket 72: the plot panel at 260 and 520 px in Night, Day, and Dracula, with an edit clash, a
    /// missing link, the link editor, and an add row. Its ground follows a config reload at once.
    @Test func showsThePlotPanelAtEachWidthAndTheme() async throws {
        try await expectPass("panel-shot", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "XDG_CONFIG_HOME": "/nonexistent-loam-driver-xdg",
        ])
    }

    @Test func failsAnUnknownScenario() async throws {
        let run = try await drive("no-such-scenario")
        #expect(run.exitCode == 1)
        #expect(run.log.contains("FAIL no-such-scenario: unknown scenario"))
    }
}
