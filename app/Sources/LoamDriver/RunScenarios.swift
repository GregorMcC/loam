import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 203: Today and the run page in the real window. The core starts five
/// runs in two plots with a fake `claude` that exits at once, and `loam run hook` moves them as Claude
/// Code's hooks do: one is ready, one stopped at the gate, one stopped by a limit, one runs, and one
/// you cancelled. The Today row in the sidebar opens Today, a run row opens its page, and Back goes
/// to Today. Temp `LOAM_HOME`, temp repo, and fake HOME only.
@MainActor
extension Scenarios {
    private static func confirm(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func todayShot(_ app: DriverApp) async throws {
        do { try await todayShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func todayShotSteps(_ app: DriverApp) async throws {
        let fm = FileManager.default
        let (rig, environment, _) = try shotRig(app)

        // A repo with one commit. The runs start their worktrees from main, so no remote is needed.
        let repo = rig.root.appendingPathComponent("widgets")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(repo, ["init", "-q", "-b", "main"])
        try "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-q", "-m", "first"])
        // Claude Code trusts a worktree when it trusts the main checkout, so the runs need the repo trusted.
        let plots = rig.loamHome.appendingPathComponent("plots").path
        try rig.trust([plots, repo.path])

        let plot = try rig.newPlot("Loam v1 build")
        let other = try rig.newPlot("Reporting")
        try rig.loam(["repo", "add", plot, repo.path])
        try rig.loam(["repo", "add", other, repo.path])
        let extra = ["PATH": environment["PATH"] ?? "/usr/bin:/bin"]

        /// Starts a run and returns its ID.
        func start(_ plot: String, _ title: String, checks: [String], maxTries: Int = 3, link: String? = nil) throws -> String {
            var args = ["run", "start", plot, "--title", title, "--goal", "\(title).", "--base", "main",
                        "--max-tries", String(maxTries)]
            for check in checks { args += ["--check", check] }
            if let link { args += ["--link", link] }
            let text = try rig.loam(args + ["--json"], extra: extra)
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            guard let id = (object?["run"] as? [String: Any])?["id"] as? String else {
                throw DriverFailure("run start printed no run: \(text)")
            }
            return id
        }
        /// Sends one hook event to the run, as Claude Code does. A Stop that the gate blocks exits 2.
        func hook(_ run: String, _ fields: [String: Any]) throws {
            let input = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
            do { try rig.loam(["run", "hook", run], extra: extra, input: input) } catch where fields["hook_event_name"] as? String == "Stop" {}
        }
        func session(_ n: Int) -> String { String(format: "%08x-3136-4e86-bfde-da8facfe0523", n) }

        let ready = try start(plot, "Fix the login form", checks: ["Tests=true", "Lint=true"],
                              link: "https://github.com/example/widgets/issues/57")
        let gate = try start(plot, "Add the export button", checks: ["Tests=false"], maxTries: 1)
        let limit = try start(other, "Weekly revenue report", checks: ["Report=true"])
        for (n, run) in [ready, gate, limit].enumerated() {
            try hook(run, ["hook_event_name": "SessionStart", "session_id": session(n + 1), "source": "startup"])
        }
        try hook(ready, ["hook_event_name": "Stop", "session_id": session(1)])
        try hook(gate, ["hook_event_name": "Stop", "session_id": session(2)])
        try hook(limit, ["hook_event_name": "StopFailure", "session_id": session(3), "error": "rate_limit"])
        // The three runs above hold no slot now, so the next two start at once.
        let running = try start(plot, "Rename the settings keys", checks: ["Tests=true"])
        let cancelled = try start(other, "Tidy the old charts", checks: [])
        for (n, run) in [running, cancelled].enumerated() {
            try hook(run, ["hook_event_name": "SessionStart", "session_id": session(n + 4), "source": "startup"])
        }
        try rig.loam(["run", "stop", cancelled], extra: extra)
        // One run at a time: the run that runs holds the slot, so a new run waits for it.
        try rig.loam(["run", "limits", "--at-a-time", "1"], extra: extra)
        let queued = try start(plot, "Show the branch in the tab", checks: ["Tests=true"])

        // The intake of the plot: a map with two open tickets.
        let map = rig.root.appendingPathComponent("maps/build")
        try fm.createDirectory(at: map.appendingPathComponent("issues"), withIntermediateDirectories: true)
        for (name, text) in [
            ("map.md", "# Build\n"),
            ("issues/135-quit-during-a-merge.md", "Status: open\n\n# Driver scenario: quit during a merge\n"),
            ("issues/136-sheet-in-full-screen.md", "Status: open\n\n# Driver scenario: a sheet in full screen\n"),
        ] {
            try text.write(to: map.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try rig.loam(["link", "add", plot, "Build map", map.appendingPathComponent("map.md").path])
        // A recurring run at 22:00 every day, for the next recurring run in the sidebar.
        try rig.loam(["recurring", "add", other, "--title", "Weekly revenue report", "--prompt", "Write the weekly report.",
                      "--kind", "chore", "--days", "daily", "--at", "22:00", "--check", "Report=true"], extra: extra)
        // The usage probe of Today asks claude -p, and this claude reports 41% of the week, which resets in 4 days.
        let claude = rig.root.appendingPathComponent("bin/claude")
        let resets = Int(Date().addingTimeInterval(4 * 24 * 3600).timeIntervalSince1970)
        let report = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":0.41,"resetsAt":RESETS}}}}"#
            .replacingOccurrences(of: "RESETS", with: String(resets))
        let script = try String(contentsOf: claude, encoding: .utf8)
            .replacingOccurrences(of: "#!/bin/sh\n", with: "#!/bin/sh\nif [ \"$1\" = -p ]; then echo '\(report)'; exit 0; fi\n")
        try script.write(to: claude, atomically: true, encoding: .utf8)

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        // The size of the frame of Today in the design.
        host.window.setFrame(NSRect(x: 40, y: 40, width: 1440, height: 900), display: true)
        let model = host.model
        try await app.waitUntil("the runs load") { model.runs.count == 6 }
        try confirm(model.runs.first { $0.id == queued }?.state == .queued, "the new run does not wait for a slot")
        try confirm(model.today.needsYouCount == 2, "Today counts \(model.today.needsYouCount) runs that need you")
        try await app.waitUntil("the Today row counts 2") { app.text(of: "sidebar-today")?.contains("2") == true }

        func appearance(_ name: NSAppearance.Name) async {
            NSApp.appearance = NSAppearance(named: name)
            await app.sleep(1)
        }

        // Today, from its sidebar row.
        try app.click("sidebar-today")
        try await app.waitUntil("Today shows") { model.page == .today && app.exists("today") }
        try confirm(app.exists("today-line-\(plot)") && app.exists("today-line-\(other)"), "Today has no line rows")
        // A chip for each run on the line. A cancelled run left the line.
        try confirm([ready, gate, limit, running, queued].allSatisfy { app.exists("today-chip-\($0)") } && !app.exists("today-chip-\(cancelled)"),
                    "the chips are not the runs on the line")
        // What Today reads: the intake of the map, the limits, the usage, the recurring run, and the events.
        try await app.waitUntil("Today reads its data") {
            model.todayData.intake[plot]?.list.items.count == 2 && model.todayData.limits?.atATime == 1
                && model.todayData.usage?.sevenDay != nil && !model.todayData.recurring.isEmpty
                && !model.todayData.awayEvents.isEmpty
        }
        try await app.waitUntil("the caption") { app.text(of: "today-caption")?.contains("1 of 1 running \u{00B7} 1 waits for a slot") == true }
        try await app.waitUntil("the Intake row counts 2") { app.text(of: "sidebar-intake")?.contains("2") == true }
        try await app.waitUntil("the sidebar card") { app.text(of: "sidebar-runs-card")?.contains("41%") == true }
        try confirm(app.exists("today-limits") && app.text(of: "action-bar-plot") == "Today", "no limits, or the bar does not name Today")
        await appearance(.darkAqua)
        app.screenshot("today-night")
        await appearance(.aqua)
        app.screenshot("today-day")

        // The chip of a run at the desk opens the desk on it.
        await appearance(.darkAqua)
        try app.click("today-chip-\(gate)")
        try await app.waitUntil("the desk shows the run") { model.page == .desk && model.desk.runID == gate }
        model.showToday()
        try await app.waitUntil("Today shows again") { model.page == .today && app.exists("today-chip-\(limit)") }

        // A run that a limit stopped is not at the desk: its chip opens its page, with its state and its history.
        try app.click("today-chip-\(limit)")
        try await app.waitUntil("the run page shows") {
            model.page == .run(limit) && model.runStatus?.run.id == limit && app.exists("run-page-history")
        }
        try confirm(app.text(of: "run-page-state")?.contains("Stopped") == true, "the state is \(app.text(of: "run-page-state") ?? "none")")
        try confirm(app.exists("run-page-watch"), "Watch is missing")
        app.screenshot("run-page-night")
        await appearance(.aqua)
        app.screenshot("run-page-day")

        // Back goes to Today. A move to a plot closes the page and shows its panes again.
        try app.click("run-page-back")
        try await app.waitUntil("Back shows Today") { model.page == .today && app.exists("today") }
        model.activate(plot: plot)
        try await app.waitUntil("the plot shows") { model.page == nil && !app.exists("today") }
        NSApp.appearance = nil
    }

    static func intakeShot(_ app: DriverApp) async throws {
        do { try await intakeShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// Ticket 204: the Intake page of a plot with a GitHub repo and a map. The fake gh lists two issues, and the map
    /// has two open tickets. A click on a ticket shows its detail, and two checked issues show the bar. Start as a
    /// chore opens the start form in a sheet, and Start run starts a run in the core and shows its page. The origin is on GitHub over SSH, and a fake ssh serves the local bare repo, so no git command
    /// reaches the network. `LOAM_DRIVER_FAKE_GH` names the fake gh.
    private static func intakeShotSteps(_ app: DriverApp) async throws {
        let fm = FileManager.default
        guard let fakeGH = ProcessInfo.processInfo.environment["LOAM_DRIVER_FAKE_GH"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_GH does not name the fake gh")
        }
        let (rig, shotEnvironment, _) = try shotRig(app)
        let (repo, ssh) = try widgetsRepo(rig, onGitHub: true)
        let ghState = rig.root.appendingPathComponent("gh-state.json")
        try #"{"issues": [{"number": 52, "title": "Paste a long prompt without a hang", "url": "https://github.com/example/widgets/issues/52", "labels": [], "updatedAt": "2026-10-22T09:00:00Z", "createdAt": "2026-10-21T09:00:00Z", "body": "A paste of 4000 characters hangs the pane for a second.", "assignees": []}, {"number": 48, "title": "Install fails when the bin folder is missing", "url": "https://github.com/example/widgets/issues/48", "labels": [{"name": "bug"}], "updatedAt": "2026-10-20T10:00:00Z", "createdAt": "2026-10-18T10:00:00Z", "body": "The install script stops when ~/.local/bin is missing.", "assignees": []}]}"#
            .write(to: ghState, atomically: true, encoding: .utf8)

        // A map with two open tickets and one resolved ticket.
        let map = rig.root.appendingPathComponent("maps/build")
        try fm.createDirectory(at: map.appendingPathComponent("issues"), withIntermediateDirectories: true)
        for (name, text) in [
            ("map.md", "# Build\n"),
            ("issues/135-quit-during-a-merge.md",
             "Status: open\nBlocked by: none\n\n# Driver scenario: quit during a merge\n\nQuit Loam while a merge runs. The quit waits for the merge.\n"),
            ("issues/136-sheet-in-full-screen.md", "Status: open\nBlocked by: 135\n\n# Driver scenario: a sheet in full screen\n"),
            ("issues/99-home-space.md", "Status: resolved\n\n# A Home space\n"),
        ] {
            try text.write(to: map.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let environment = shotEnvironment.merging([
            "LOAM_GH": fakeGH, "LOAM_FAKE_GH_STATE": ghState.path,
            "LOAM_FAKE_GH_LOG": rig.root.appendingPathComponent("gh-calls.jsonl").path,
            "GIT_SSH_COMMAND": ssh,
        ]) { $1 }
        let plot = try rig.newPlot("Loam v1 build")
        // The fake ssh serves the fetch of repo add, so it does not reach GitHub.
        try rig.loam(["repo", "add", plot, repo.path], extra: environment)
        try rig.loam(["link", "add", plot, "Build map", map.appendingPathComponent("map.md").path])
        // A rule of the plot, which the detail lists under Claude reads first.
        try rig.loam(["rule", "add", plot, "--name", "Views use LoamColor tokens", "--command", "true"])
        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        intakeFrameSize(host.window)
        let model = host.model
        try await app.waitUntil("the plot loads") { model.plots.count == 1 && model.workspace.activePlotID == plot }

        func appearance(_ name: NSAppearance.Name) async {
            NSApp.appearance = NSAppearance(named: name)
            await app.sleep(1)
        }

        try app.click("sidebar-intake")
        try await app.waitUntil("the intake shows") { model.page == .intake(plot) && app.exists("intake-row-map 135") }
        try confirm(app.exists("intake-row-#52") && app.exists("intake-row-#48") && app.exists("intake-row-map 136")
                    && !app.exists("intake-row-map 99"), "the rows are not the open issues and tickets")
        // The bar names the page and the plot, and the sidebar card says when the app read each source.
        try confirm(app.text(of: "action-bar-plot") == "Intake" && app.text(of: "action-bar-pane") == "Loam v1 build",
                    "the bar does not name the Intake page")
        try await app.waitUntil("the sources card") { app.text(of: "sidebar-sources-card")?.contains("Read just now") == true }
        try app.click("intake-filter-map")
        try await app.waitUntil("the map filter") { !app.exists("intake-row-#52") && app.exists("intake-row-map 136") }
        try app.click("intake-filter-all")
        try await app.waitUntil("all items") { app.exists("intake-row-#52") }

        // The detail of a ticket, and two checked issues with the bar.
        try app.click("intake-row-map 135")
        try await app.waitUntil("the detail shows") {
            app.exists("intake-detail") && app.exists("intake-chore") && app.exists("intake-when-shaped")
                && app.exists("intake-reads-first") && app.exists("intake-text")
        }
        try app.click("intake-check-#52")
        try app.click("intake-check-#48")
        try await app.waitUntil("the bar shows") { app.text(of: "intake-batch-start") == "Shape 2 runs" }
        await appearance(.darkAqua)
        app.screenshot("intake-night")
        await appearance(.aqua)
        app.screenshot("intake-day")
        await appearance(.darkAqua)
        try app.click("intake-check-#52")
        try app.click("intake-check-#48")
        try await app.waitUntil("the bar goes") { !app.exists("intake-batch") }

        // The start form of the ticket, in a sheet.
        try app.click("intake-chore")
        try await app.waitUntil("the start form") { app.exists("intake-start") && app.window.attachedSheet != nil }
        try app.fill("intake-goal", with: "A driver scenario quits Loam while a merge runs, and the quit waits.")
        try app.fill("intake-check-name-0", with: "Tests")
        try app.fill("intake-check-command-0", with: "true")
        // TAS-21: the Base picker starts on the default branch of origin.
        try await app.waitUntil("the Base picker shows") { app.exists("intake-base") }
        try confirm(model.runBases?.items.first?.title == "origin/main" && model.runBases?.first == nil,
                    "the bases are \(String(describing: model.runBases))")
        await app.sleep(0.5)
        app.screenshot("intake-sheet-night", of: app.window.attachedSheet)

        try app.click("intake-start")
        try await app.waitUntil("the run page of the new run") {
            if case .run = model.page { return model.runStatus != nil && app.exists("run-page-history") }
            return false
        }
        guard let run = model.runStatus?.run else { throw DriverFailure("no run") }
        try confirm(run.source?.kind == "map" && run.source?.key == "map 135", "the run source is \(String(describing: run.source))")
        try confirm(run.doneWhen == [RunCheck(name: "Tests", command: "true")], "the checks are \(run.doneWhen)")
        app.screenshot("intake-run-page")

        // Back on Intake, the ticket shows its run.
        await model.showIntake(plot: plot)
        try await app.waitUntil("the ticket has its run") {
            model.intake?.items.first { $0.key == "map 135" }?.runID == run.id
        }
        // The row of the ticket goes last, with the station of its run and no check box.
        try await app.waitUntil("the row shows its run") { !app.exists("intake-check-map 135") }
        await app.sleep(0.5)
        app.screenshot("intake-with-run-night")

        // TAS-21: a repo with no origin. The picker starts on the branch of the checkout, and the run starts from it.
        try git(repo, ["remote", "remove", "origin"])
        try app.click("intake-row-map 136")
        try await app.waitUntil("the detail of the ticket") { app.exists("intake-chore") }
        try app.click("intake-chore")
        try await app.waitUntil("the Base picker shows the branch") {
            app.exists("intake-start") && app.exists("intake-base") && model.runBases?.first == "main"
        }
        try app.click("intake-start")
        try await app.waitUntil("the run starts from main") {
            if case .run(let id) = model.page { return id != run.id && model.runStatus?.run.id == id }
            return model.runStartError != nil
        }
        try confirm(model.runStartError == nil, "the run did not start: \(model.runStartError ?? "")")
        NSApp.appearance = nil
    }

    static func linearShot(_ app: DriverApp) async throws {
        do { try await linearShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// Ticket 205: Settings > Connections takes a Linear API key, and the Intake page of a plot with a Linear team
    /// link lists its issues. A run from an issue moves the issue to In Progress. The Linear API is the core's fake
    /// (`LOAM_DRIVER_FAKE_LINEAR`), on a local port, and a temp secrets file stands in for the Keychain.
    private static func linearShotSteps(_ app: DriverApp) async throws {
        guard let fakeLinear = ProcessInfo.processInfo.environment["LOAM_DRIVER_FAKE_LINEAR"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_LINEAR does not name the fake Linear")
        }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: fakeLinear)
        let out = Pipe()
        server.standardOutput = out
        try server.run()
        defer { server.terminate() }
        // The first line is the URL of the API.
        var line = Data()
        while let byte = try out.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data("\n".utf8) {
            line.append(byte)
        }
        let apiURL = String(decoding: line, as: UTF8.self)
        try confirm(apiURL.hasPrefix("http://127.0.0.1:"), "the fake Linear printed \(apiURL)")

        let (rig, shotEnvironment, _) = try shotRig(app)
        let (repo, _) = try widgetsRepo(rig, onGitHub: false)
        let website = try rig.newPlot("Website")
        try rig.loam(["link", "add", website, "Website in Linear", "https://linear.app/acme/project/website-redesign-8f3a2b1c9d0e/overview"])
        _ = try rig.newPlot("Release notes")
        let plot = try rig.newPlot("Loam v1 build")
        try rig.loam(["repo", "add", plot, repo.path])
        try rig.loam(["link", "add", plot, "ENG team", "https://linear.app/acme/team/ENG/active"])

        let environment = shotEnvironment.merging([
            "LOAM_LINEAR_URL": apiURL, "LOAM_SECRETS_FILE": rig.root.appendingPathComponent("secrets.json").path,
        ]) { $1 }
        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        intakeFrameSize(host.window)
        let model = host.model
        try await app.waitUntil("the plot loads") { model.plots.count == 3 }
        if model.workspace.activePlotID != plot {
            try app.click("plot-\(plot)")
            try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Settings > Connections: no key, then a key that Linear takes.
        try app.pressMenuKey(",")
        func settingsWindow() -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue == "dev.loam.settings" && $0.isVisible }
        }
        try await app.waitUntil("the settings window") { settingsWindow() != nil }
        guard let tabs = settingsWindow()?.contentViewController as? NSTabViewController,
              let index = tabs.tabViewItems.firstIndex(where: { ($0.identifier as? String) == "Connections" }) else {
            throw DriverFailure("the settings window has no Connections tab")
        }
        tabs.selectedTabViewItemIndex = index
        try await app.waitUntil("no key yet") { model.connections.linearWords == "No Linear API key." }
        try app.fill("settings-linear-key", with: "lin_api_good")
        try await app.waitUntil("Save is on") { AccessibilityProbe.shared.isEnabled("settings-linear-save") }
        try app.click("settings-linear-save")
        try await app.waitUntil("the key is taken") { model.connections.linearWords == "Connected to Acme as Ada Example." }
        try await app.waitUntil("the mask") { app.exists("settings-linear-mask") && model.connections.scopeRows.count == 3 }
        try confirm(model.connections.scopeRows.map(\.scope).contains("WEB team") == false, "a project link reads as a team")
        try confirm(model.connections.scopeRows.map(\.scope).contains("Website redesign project"), "no project scope")
        // A switch is saved through the core.
        try app.click("settings-update-walkthrough")
        try await app.waitUntil("the walkthrough switch") { model.connections.updates?.walkthroughComment == true }
        await app.sleep(0.5)
        app.screenshot("connections", of: settingsWindow())
        // Disconnect asks in place, and Cancel keeps the key.
        try app.click("settings-linear-disconnect")
        try await app.waitUntil("the confirm") { app.exists("settings-linear-remove-cancel") }
        app.screenshot("connections-confirm", of: settingsWindow())
        try app.click("settings-linear-remove-cancel")
        try await app.waitUntil("the confirm is gone") { !app.exists("settings-linear-remove-cancel") }
        try confirm(model.connections.linear?.connected == true, "Cancel removed the key")

        // The Runs tab.
        if let index = tabs.tabViewItems.firstIndex(where: { ($0.identifier as? String) == "Runs" }) {
            tabs.selectedTabViewItemIndex = index
            try await app.waitUntil("the limits") { model.runsSettings.limits != nil && app.exists("settings-runs-at-a-time") }
            await app.sleep(0.5)
            app.screenshot("runs-settings", of: settingsWindow())
        } else {
            throw DriverFailure("the settings window has no Runs tab")
        }
        settingsWindow()?.close()

        // Intake lists the issues of the team.
        try app.click("sidebar-intake")
        try await app.waitUntil("the Linear issues") { app.exists("intake-row-ENG-523") && app.exists("intake-row-ENG-525") }
        try confirm(app.exists("intake-filter-linear"), "no Linear filter")
        try confirm(app.exists("intake-this-cycle"), "no This cycle chip")
        try app.click("intake-row-ENG-523")
        try await app.waitUntil("the detail") { app.exists("intake-chore") && app.exists("intake-text") }
        try app.click("intake-check-ENG-523")
        try await app.waitUntil("the bar shows") { app.exists("intake-batch-start") }
        await app.sleep(0.5)
        app.screenshot("intake-linear-night")
        NSApp.appearance = NSAppearance(named: .aqua)
        await app.sleep(1)
        app.screenshot("intake-linear-day")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try app.click("intake-check-ENG-523")
        try await app.waitUntil("the bar goes") { !app.exists("intake-batch") }
        // This cycle keeps only the issue in the active cycle.
        try app.click("intake-this-cycle")
        try await app.waitUntil("this cycle") { app.exists("intake-row-ENG-523") && !app.exists("intake-row-ENG-525") }
        try app.click("intake-this-cycle")

        try app.click("intake-chore")
        try await app.waitUntil("the start form") { app.exists("intake-start") }
        try app.fill("intake-goal", with: "A link row moves with a drag, and the order stays after a restart.")

        // The run moves the issue to In Progress, and its history says so.
        try app.click("intake-start")
        try await app.waitUntil("the run page") {
            if case .run = model.page { return model.runStatus?.events.contains { $0.kind == "linear" } == true }
            return false
        }
        let event = model.runStatus?.events.first { $0.kind == "linear" }
        try confirm(event?.detail == "Moved ENG-523 to In Progress", "the Linear event is \(String(describing: event))")
        await app.sleep(0.5)
        app.screenshot("linear-run-page")
        NSApp.appearance = nil
    }

    /// The Intake shots take the size of the design frame, 1440 by 900, or the screen when it is smaller.
    static func intakeFrameSize(_ window: NSWindow) {
        let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1440, screen.width), height: min(900, screen.height))
        window.setFrame(NSRect(x: screen.minX, y: screen.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// A repo, widgets, on branch main with one commit and a local bare origin, and Claude Code trusts it. A run
    /// branches from origin's default branch. With `onGitHub`, origin is example/widgets on GitHub over SSH, and
    /// `ssh` is a fake ssh for `GIT_SSH_COMMAND` that serves the bare repo, so no git command reaches the network.
    static func widgetsRepo(_ rig: PanelRig, onGitHub: Bool) throws -> (repo: URL, ssh: String) {
        let fm = FileManager.default
        let origin = rig.root.appendingPathComponent("origin.git")
        let repo = rig.root.appendingPathComponent("widgets")
        try fm.createDirectory(at: origin, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(origin, ["init", "--bare", "-q", "-b", "main"])
        try git(repo, ["init", "-q", "-b", "main"])
        try "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-q", "-m", "first"])
        try git(repo, ["remote", "add", "origin", origin.path])
        try git(repo, ["push", "-q", "origin", "main"])
        try git(repo, ["remote", "set-head", "origin", "main"])
        let ssh = rig.root.appendingPathComponent("fake-ssh")
        if onGitHub {
            try git(repo, ["remote", "set-url", "origin", "git@github.com:example/widgets.git"])
            // git runs: <ssh> <host> "<git program> '<repo>'". The fake serves the bare repo for any GitHub repo.
            try "#!/bin/sh\nprog=${2%% *}\nexec git \"${prog#git-}\" '\(origin.path)'\n"
                .write(to: ssh, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        }
        try rig.trust([rig.loamHome.appendingPathComponent("plots").path, repo.path])
        return (repo, ssh.path)
    }

    static func shipShot(_ app: DriverApp) async throws {
        do { try await shipShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// Ticket 206: Ship in the real window. A run whose checks pass goes to Ship, and a tick pushes its branch and
    /// opens PR #1. CI fails, so the tick sends the failure back to the session as a try. The fix passes the checks,
    /// the tick pushes it to #1, CI passes, and the run waits on the Land tile of Today. The fake gh
    /// (`LOAM_DRIVER_FAKE_GH`) stands in for GitHub, and the scenario writes its CI state.
    private static func shipShotSteps(_ app: DriverApp) async throws {
        let gh = try GitHubRun(app, title: "Plot search matches link labels", goal: "A search for a link label finds its plot.")
        let (run, rig, environment) = (gh.id, gh.rig, gh.environment)
        try gh.commitAndStop("search.txt")

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        let model = host.model
        try await app.waitUntil("the run ships") { model.runs.first?.state == .shipping }
        func appearance(_ name: NSAppearance.Name) async {
            NSApp.appearance = NSAppearance(named: name)
            await app.sleep(1)
        }

        // Today shows the run at Ship.
        await appearance(.darkAqua)
        try app.click("sidebar-today")
        try await app.waitUntil("Today shows") { model.page == .today && app.exists("today-chip-\(run)") }
        app.screenshot("ship-today-shipping")

        // A tick pushes the branch and opens #1.
        await model.tickRuns()
        try await app.waitUntil("the run has its PR") { model.runs.first?.pr?.number == 1 }
        try app.click("today-chip-\(run)")
        try await app.waitUntil("the run page shows #1") {
            model.runStatus?.run.id == run && app.exists("run-page-pr")
                && model.runStatus?.events.contains { $0.detail == "Opened #1" } == true
        }
        app.screenshot("ship-run-page-pr")

        // CI fails: the failure goes back to the session as a try.
        try gh.setCI("FAILURE")
        await model.tickRuns()
        try await app.waitUntil("the run runs again") {
            model.runStatus?.run.state == .running && model.runStatus?.run.note == "CI failed on #1: ci / test"
        }
        try confirm(model.runStatus?.run.tries == 1, "the tries are \(String(describing: model.runStatus?.run.tries))")
        app.screenshot("ship-ci-failed")

        // The fix passes the checks, and a tick pushes it to #1.
        try gh.commitAndStop("labels.txt")
        await model.tickRuns()
        await model.reloadRuns()
        try await app.waitUntil("the fix is on #1") {
            model.runStatus?.events.contains { $0.detail == "Pushed the fix to #1" } == true
        }

        // CI passes: the run is ready to land.
        try gh.setCI("SUCCESS")
        await model.tickRuns()
        try await app.waitUntil("the run is ready") {
            model.runStatus?.run.state == .ready && model.runStatus?.run.note == "CI passed on #1: 1 of 1 checks"
        }
        app.screenshot("ship-run-page-ready-night")
        await appearance(.aqua)
        app.screenshot("ship-run-page-ready-day")
        try app.click("run-page-back")
        try await app.waitUntil("Today shows") { model.page == .today && app.exists("today") }
        await appearance(.darkAqua)
        app.screenshot("ship-today-land-night")
        await appearance(.aqua)
        app.screenshot("ship-today-land-day")
        NSApp.appearance = nil
    }
}
