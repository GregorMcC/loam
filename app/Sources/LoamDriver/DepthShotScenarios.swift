import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 120: the depth of the things that float over the window. It takes shots of the Land sheet
/// (ready and blocked), the PR popover with failed checks, the New worktree sheet and the ⌘J menu, with the plot panel
/// open, in Loam Night, Loam Day and Catppuccin Mocha. It uses the made-up repo and the fake `gh` of the Land scenario,
/// a temp `LOAM_HOME`, and no config of yours.
@MainActor
extension Scenarios {
    private static func expectDepth(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func depthShot(_ app: DriverApp) async throws {
        do { try await depthShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func depthShotSteps(_ app: DriverApp) async throws {
        guard let fakeGH = ProcessInfo.processInfo.environment["LOAM_DRIVER_FAKE_GH"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_GH does not name the fake gh")
        }
        let rig = try PanelRig(outFolder: app.outFolder)
        let ghState = rig.root.appendingPathComponent("gh-state.json")

        // A plot with two worktrees: link-labels is ready to merge, and native-panel has failed checks and 2 files that are
        // not committed. The remote becomes a GitHub address after the worktrees exist, so no git command asks the network.
        let plot = try rig.newPlot("Widgets plot")
        let widgets = try makeRepo(rig, named: "widgets")
        try rig.loam(["repo", "add", plot, widgets.path])
        let labels = try makeWorktree(rig, plot: plot, repo: widgets, name: "link-labels")
        let panel = try makeWorktree(rig, plot: plot, repo: widgets, name: "native-panel")
        for name in ["notes.txt", "todo.txt"] {
            try "draft\n".write(to: URL(fileURLWithPath: panel.path).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try git(widgets, ["remote", "set-url", "origin", "https://github.com/example/widgets.git"])
        try landGitHub(head: try headCommit(of: labels.path)).write(to: ghState)
        try rig.loam(["set", plot, "where-it-stands", "Building the link labels."])

        let client = LoamClient(binary: rig.binary, environment: rig.environment.merging(try rig.neutralPrompt()) { $1 }.merging([
            "LOAM_GH": fakeGH, "LOAM_FAKE_GH_STATE": ghState.path,
            "LOAM_FAKE_GH_LOG": rig.root.appendingPathComponent("gh-calls.jsonl").path,
        ]) { $1 })
        // The timers are far away, so only the launch and the opens of the popover and the sheet ask GitHub.
        let host = try await app.launchApp(client: client, state: rig.stateFile, terminals: true) { host in
            host.model.shipRefresh.timing.activeInterval = .seconds(3600)
            host.model.shipRefresh.timing.otherInterval = .seconds(3600)
        }
        app.runtime.applyWindowAppearance(to: host.window)
        host.window.setFrame(NSRect(x: 80, y: 80, width: 1360, height: 760), display: true)
        let model = host.model
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }
        try await app.waitUntil("the stages") {
            model.worktreeStatus(labels.id)?.stage == .readyToMerge && model.worktreeStatus(panel.id)?.stage == .checksFailed
        }
        // A shell in link-labels, so the well holds terminal text under the scrim, and the plot panel on the right.
        guard let worktree = model.worktreeStatus(labels.id)?.worktree else { throw DriverFailure("no worktree link-labels") }
        model.openWorktreePane(worktree, kind: .shell)
        try await app.waitUntil("the shell is focused") { model.focusedWorktree?.id == labels.id }
        try await app.openPanel(host)

        /// The shot waits for the card to drop in.
        func settledShot(_ name: String) async throws {
            try await Task.sleep(for: .seconds(LoamTheme.durationSlow * 2))
            app.screenshot(name)
        }
        func landShot(_ id: String, number: Int, _ name: String) async throws {
            try expectDepth(model.openLandSheet(id), "the sheet did not open for #\(number)")
            try await app.waitUntil("the sheet shows the plan of #\(number)") {
                model.landContent?.number == number && app.exists("land-sheet-footer") && app.exists("land-sheet-merge")
            }
            try await settledShot(name)
            // Ticket 126: the scrim covers the title bar in the shot, and goes with the sheet.
            try await expectTitleBarScrim(app, host, shown: true)
            model.closeLandSheet()
            try await app.waitUntil("the sheet closes") { !app.exists("land-sheet") }
            try await expectTitleBarScrim(app, host, shown: false)
        }

        for (name, appearance, theme) in [("night", NSAppearance.Name.darkAqua, ""), ("day", .aqua, ""),
                                          ("catppuccin", .darkAqua, "theme = Catppuccin Mocha")] {
            if !theme.isEmpty {
                try app.writeConfig(theme)
                app.runtime.reloadConfig()
                try await app.waitUntil("the chrome follows Catppuccin Mocha", timeout: 10) {
                    ChromePalette.shared.current?.bedrock == 0x1e1e2e
                }
            }
            NSApp.appearance = NSAppearance(named: appearance)
            try await app.waitUntil("\(name): the window follows", timeout: 10) {
                (host.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) == (appearance == .darkAqua)
            }
            await app.sleep(1)

            try await landShot(labels.id, number: 22, "\(name)-land-ready")
            try await landShot(panel.id, number: 16, "\(name)-land-blocked")

            try expectDepth(model.openPullRequest(panel.id), "the popover did not open for native-panel")
            try await app.waitUntil("the popover shows the failed checks") {
                app.exists("pr-popover-failed-checks") && !model.prPopover.isRefreshing
            }
            try await settledShot("\(name)-popover-failed")
            model.closePullRequest()
            try await app.waitUntil("the popover closes") { !app.exists("pr-popover") }

            try expectDepth(model.openNewWorktree(plot: plot), "the New worktree sheet did not open")
            try await app.waitUntil("the New worktree sheet shows") { app.exists("new-worktree-start") }
            try await settledShot("\(name)-new-worktree")
            try await expectTitleBarScrim(app, host, shown: true)
            model.closeNewWorktree()
            try await app.waitUntil("the New worktree sheet closes") { !app.exists("new-worktree-sheet") }

            // The ⌘J menu: the card that the popover takes its depth from.
            app.press(letter: "j", flags: .command)
            try await app.waitUntil("\(name): the menu opens") { app.exists("actions-menu") }
            try await settledShot("\(name)-actions-menu")
            app.press(.escape)
            try await app.waitUntil("\(name): the menu closes") { !app.exists("actions-menu") }
        }
        NSApp.appearance = nil
    }
}
