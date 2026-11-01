import Foundation
import Testing

/// Runs the built app in driver mode, one scenario per test, and checks the log.
/// The app opens a window for a few seconds. The panes run `zsh -f` or
/// `bash --noprofile --norc`, so the tests cost no usage.
/// Set LOAM_SKIP_DRIVER=1 to skip them.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LOAM_SKIP_DRIVER"] == nil), .temporaryFolders)
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
        let out = temporaryFolder("driver-\(scenario)")
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
        // The driver ends itself: past the time limit of its scenario (exit 4), or when its main thread hangs (exit 3).
        // So this wait does not end a slow scenario on a busy machine (ticket 125). It ends a launch that never starts
        // the driver, with no driver.log after 5 minutes: a busy machine can hold a launch for half a minute while macOS
        // checks the binary. And it ends a driver that does not end itself, after 30 minutes, far past any limit.
        let log = out.appendingPathComponent("driver.log")
        let launched = Date()
        while exit.status == nil {
            let waited = Date().timeIntervalSince(launched)
            if waited > 300, !FileManager.default.fileExists(atPath: log.path) { break }
            if waited > 1800 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if exit.status == nil {
            kill(process.processIdentifier, SIGKILL)
            let deadline = Date().addingTimeInterval(5)
            while exit.status == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return Run(exitCode: exit.status ?? -1, log: text)
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
        let out = runFolder.appendingPathComponent("loam")
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

    /// Ticket 98: drag a tab past two others, Escape and a release outside cancel, Reduce Motion.
    @Test func dragsATabToANewSlotAndKeepsTheSelection() async throws {
        try await expectPass("tab-drag", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// Ticket 98: drag a plot down two rows, the store order and the ⌃ numbers follow, cancels, Reduce Motion.
    @Test func dragsAPlotDownTwoRowsAndStoresTheOrder() async throws {
        try await expectPass("plot-drag", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// The core's fake `claude` in hook mode, built from ../core: LOAM_DRIVER_FAKE_CLAUDE, else a build in a temp folder.
    static let fakeClaude = coreTool("fakeclaude", environment: "LOAM_DRIVER_FAKE_CLAUDE")

    /// The core's fake `gh`, built from ../core: LOAM_DRIVER_FAKE_GH, else a build in a temp folder.
    static let fakeGH = coreTool("fakegh", environment: "LOAM_DRIVER_FAKE_GH")

    /// The core's fake Linear API, built from ../core: LOAM_DRIVER_FAKE_LINEAR, else a build in a temp folder.
    static let fakeLinear = coreTool("fakelinear", environment: "LOAM_DRIVER_FAKE_LINEAR")

    /// A test tool of the core, from core/internal/testutil: the path in the environment variable, else a build in a
    /// temp folder.
    static func coreTool(_ name: String, environment: String) -> String {
        if let path = ProcessInfo.processInfo.environment[environment] { return path }
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("core")
        let out = runFolder.appendingPathComponent(name)
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["go", "build", "-o", out.path, "./internal/testutil/\(name)"]
        build.currentDirectoryURL = core
        do { try build.run() } catch { fatalError("go build did not start: \(error)") }
        build.waitUntilExit()
        if build.terminationStatus != 0 { fatalError("go build of \(name) failed with \(build.terminationStatus)") }
        return out.path
    }

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

    /// TAS-55: a session in the main checkout makes a worktree through MCP and shows under it in the sidebar.
    /// work_in_worktree with no worktree puts it back.
    @Test func aSessionThatMakesAWorktreeShowsUnderIt() async throws {
        try await expectPass("session-worktree-shot", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// Ticket 108: the Worktrees section reads the ship state from a refresh, in the order of the core. A Stop of a
    /// session makes one refresh. `gh` missing and signed out show a callout. A refresh writes no change marker.
    @Test func showsTheWorktreesSectionAndRefreshesItsShipState() async throws {
        try await expectPass("worktrees-section", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude, "LOAM_DRIVER_FAKE_GH": Self.fakeGH,
        ])
    }

    /// Ticket 109: the chip of the action bar opens the PR popover, which asks about one worktree and runs Re-run failed
    /// and Update branch through `loam`. Escape gives the keys back. The switcher, the sidebar, ⌘⇧L and the ⌘J menu open it.
    @Test func opensThePullRequestPopoverFromTheChipAndTheMenus() async throws {
        try await expectPass("pr-popover", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_GH": Self.fakeGH,
        ])
    }

    /// Ticket 110: the PR popover types a fix prompt into an idle session, which gets it only on Return. A busy session
    /// and a key after the Stop show Copy prompt, and a worktree with no session starts one that gets the prompt.
    @Test func sendsAFixPromptToTheSessionOfAWorktree() async throws {
        try await expectPass("send-to-session", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude, "LOAM_DRIVER_FAKE_GH": Self.fakeGH,
        ])
    }

    /// Ticket 112: the Land sheet. A blocked worktree keeps Merge off, a worktree with running checks merges when ready,
    /// a refused merge leaves the sheet open with the message of GitHub, and a merge of a worktree with a shell open closes the
    /// pane, removes the worktree, saves Where it stands as one change, and shows the toast. Tab and Shift-Tab keep the keys in
    /// the sheet (ticket 123).
    @Test func landsAWorktreeFromTheLandSheet() async throws {
        try await expectPass("land-sheet", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_GH": Self.fakeGH,
        ])
    }

    /// Ticket 113: after a merge on GitHub. A repo that asks shows a callout: Keep leaves the faded row, and Remove worktree
    /// removes the worktree and gives Where it stands the keys. A repo set to Remove the worktree removes a clean worktree
    /// with a toast, and asks for one with changed files and for one with a shell that runs a process.
    @Test func actsAfterAMergeOnGitHub() async throws {
        try await expectPass("after-merge", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_GH": Self.fakeGH,
        ])
    }

    /// Ticket 115: Start work… on a Linear issue link fills the New worktree sheet. The sheet checks the branch as you type,
    /// Start session makes the worktree and starts a seeded session in it, the issue key shows on the rows, and the plus of
    /// the Worktrees section opens the sheet with no link. Ticket 123: Tab and Shift-Tab move through the fields of the
    /// sheet, and keep the keys in the sheet and in the PR popover.
    @Test func startsWorkFromALink() async throws {
        try await expectPass("start-work", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude,
        ])
    }

    /// Ticket 120: the Land sheet, the PR popover, the New worktree sheet and the ⌘J menu over the window with the plot
    /// panel open, in Loam Night, Loam Day and Catppuccin Mocha.
    @Test func showsTheDepthOfTheSheetsAndThePopover() async throws {
        try await expectPass("depth-shot", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_GH": Self.fakeGH, "XDG_CONFIG_HOME": "/nonexistent-loam-driver-xdg",
        ])
    }

    /// Ticket 126: the scrim of a sheet covers the title bar and the toolbar, and keeps the window buttons clear. While the New
    /// worktree sheet shows, no toolbar item takes a press. With the sheet closed, the scrim goes and the items act.
    @Test func coversTheToolbarUnderASheet() async throws {
        try await expectPass("toolbar-sheet", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
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
        let rig = temporaryFolder("driver-restore").appendingPathComponent("rig")
        let environment = [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude, "LOAM_DRIVER_RIG": rig.path,
        ]
        try await expectPass("restore-quit", environment: environment)
        try await expectPass("restore-relaunch", environment: environment)
    }

    /// Ticket 99: a store with no plot opens Home, and ⌘T starts a session there with no plot. ⌃0, ⌘⌥T,
    /// and ⌘J "New session in Home" work from a plot. A relaunch brings the Home tabs back and resumes each session.
    @Test func opensTabsInHomeAndRestoresThem() async throws {
        let rig = temporaryFolder("driver-home").appendingPathComponent("rig")
        let environment = [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude, "LOAM_DRIVER_RIG": rig.path,
        ]
        try await expectPass("home", environment: environment)
        try await expectPass("home-relaunch", environment: environment)
    }

    /// Ticket 100: ⌘J moves a Home tab of a shell and a session to a plot. The shell keeps its process,
    /// and the session resumes in the plot. "Move to New Plot…" makes a plot first. A relaunch
    /// brings the moved tab back in the plot.
    @Test func movesAHomeTabToAPlot() async throws {
        let rig = temporaryFolder("driver-move").appendingPathComponent("rig")
        let environment = [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude, "LOAM_DRIVER_RIG": rig.path,
        ]
        try await expectPass("move-to-plot", environment: environment)
        try await expectPass("move-to-plot-relaunch", environment: environment)
    }

    /// Ticket 32: 3 plots, a permission prompt in a plot that is not active shows on its sidebar row,
    /// ⌘L reaches it, and a key clears it. Also done, unread, the banner, the title bar button, and Reduce Motion.
    @Test func showsAPaneThatNeedsYouAndReachesItWithCommandL() async throws {
        try await expectPass("attention", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude,
        ])
    }

    /// Ticket 203: five runs in two plots. The Today row opens Today with its tiles, the line, and the runs.
    /// A run row opens the run page with its note and history, and Back goes to Today.
    @Test func showsTodayAndTheRunPage() async throws {
        try await expectPass("today-shot", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude,
        ])
    }

    /// TAS-46: ⌘[ and ⌘] and the mouse back and forward buttons go back and forward through Today, Intake, the desk and
    /// a run page. In a split tab, ⌘[ and ⌘] still move the focus between the panes and leave the history alone.
    @Test func goesBackAndForwardBetweenPages() async throws {
        try await expectPass("history-shot", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_CLAUDE": Self.fakeClaude,
        ])
    }

    /// Ticket 204: the Intake page lists two GitHub issues and two open map tickets, filters them, and starts a run
    /// from a ticket through the core. The new run shows its page, and the ticket shows its run.
    @Test func listsTheIntakeAndStartsARunFromATicket() async throws {
        try await expectPass("intake-shot", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_GH": Self.fakeGH,
        ])
    }

    /// Ticket 205: Settings > Connections takes a Linear API key, Intake lists the issues of a Linear team link, and a
    /// run from an issue moves the issue to In Progress.
    @Test func connectsLinearAndStartsARunFromAnIssue() async throws {
        try await expectPass("linear-shot", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_LINEAR": Self.fakeLinear,
        ])
    }

    /// Ticket 206: a run whose checks pass ships. A tick pushes it and opens #1, a CI failure goes back to the session
    /// as a try, the fix goes to #1, and CI passes, so the run waits on the Land tile.
    @Test func shipsARunThroughAFailedCIToLand() async throws {
        try await expectPass("ship-shot", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_GH": Self.fakeGH,
        ])
    }

    /// Ticket 207: the Land tile opens the desk on a ready run, with its diff. A note on a line goes back to the
    /// session, the change comes back through the gate and CI, and Merge lands the run.
    @Test func reviewsARunAtTheDeskSendsANoteBackAndMergesIt() async throws {
        try await expectPass("desk-shot", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_GH": Self.fakeGH,
        ])
    }

    /// TAS-53: a run whose PR has no CI is ready, and the desk says "no CI". A commit after Ready ships the run
    /// again, and the desk shows the diff of the PR with the commit.
    @Test func shipsACommitAfterReadyAndTheDeskSaysNoCI() async throws {
        try await expectPass("desk-no-ci-shot", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_GH": Self.fakeGH,
        ])
    }

    /// TAS-61: the desk shows the review of the PR of a Ready run. With no review, Merge is the main action. With changes
    /// requested and 2 open threads, the Review row opens to the 2 comments as plain text, and Send review back is the
    /// main action and resumes the session. An approved PR keeps Merge as the main action.
    @Test func showsTheReviewOfAReadyRunAtTheDeskAndSendsItBack() async throws {
        try await expectPass("desk-review-shot", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_GH": Self.fakeGH,
        ])
    }

    /// Ticket 207: Claude drafts a run from a ticket. The Shape tile opens the desk on the draft, a changed
    /// assumption is typed, and A approves the run, which starts with the change.
    @Test func shapesARunAtTheDeskChangesAnAssumptionAndApprovesIt() async throws {
        try await expectPass("shape-shot", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// TAS-176: the Metrics page shows where the time of the landed runs goes, a slow run opens its page, and Fix this
    /// drafts a run that fixes it.
    @Test func showsTheMetricsAndFixesALandedRun() async throws {
        try await expectPass("metrics-shot", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// Ticket 208: a skipped chore shows on the Recurring page, a new Shape run is typed and added, Run now drafts
    /// a run, and the switch installs the launchd agent.
    @Test func addsARecurringRunAndRunsItNow() async throws {
        try await expectPass("recurring-shot", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// TAS-63: the MCP servers of the run defaults. You select 1 server and `loam run defaults` shows it, you clear it
    /// and the list is empty, and a selected server that the config lacks shows "not found" until you clear it.
    @Test func picksTheMCPServersOfTheRunDefaults() async throws {
        try await expectPass("run-defaults-mcp-shot", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// TAS-64: the code review of the run defaults. It is on by default. You pick an effort, turn it off, and turn
    /// it on again, and `loam run defaults` shows each change. The effort picker is off while the review is off.
    @Test func setsTheCodeReviewOfTheRunDefaults() async throws {
        try await expectPass("run-defaults-review-shot", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// TAS-175: the sandbox settings. You add a host and a path in the run defaults of a plot, a path that opens home
    /// is refused with its reason, and Settings > Runs holds the machine scope apart from the plot scope.
    @Test func addsPathsAndHostsToTheSandbox() async throws {
        try await expectPass("sandbox-settings-shot", environment: ["LOAM_DRIVER_LOAM": Self.loamBinary])
    }

    /// Ticket 107: two plots with a worktree each that is ready to merge. The Ready to merge row counts 2,
    /// ⌘⇧L selects the first, then the second, then the first again, and the row goes while gh is missing.
    @Test func reachesTheWorktreesThatAreReadyToMergeWithCommandShiftL() async throws {
        try await expectPass("ready-to-merge", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_GH": Self.fakeGH,
        ])
    }

    /// Ticket 107: a worktree row that no repo row holds sits right under its plot. ⌘⇧L selects it, and the
    /// row shows as selected, as a row under a repo row does.
    @Test func selectsAWorktreeRowThatSitsUnderItsPlot() async throws {
        try await expectPass("ready-to-merge-homeless", environment: [
            "LOAM_DRIVER_LOAM": Self.loamBinary, "LOAM_DRIVER_FAKE_GH": Self.fakeGH,
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
