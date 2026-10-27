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
        let trusted = [plots, repo.path].map { "\"\($0)\": {\"hasTrustDialogAccepted\": true}" }.joined(separator: ", ")
        try "{\"projects\": {\(trusted)}}".write(to: rig.fakeHome.appendingPathComponent(".claude.json"),
                                                  atomically: true, encoding: .utf8)

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
        let running = try start(plot, "Rename the settings keys", checks: ["Tests=true"])
        let cancelled = try start(other, "Tidy the old charts", checks: [])
        for (n, run) in [ready, gate, limit, running, cancelled].enumerated() {
            try hook(run, ["hook_event_name": "SessionStart", "session_id": session(n + 1), "source": "startup"])
        }
        try hook(ready, ["hook_event_name": "Stop", "session_id": session(1)])
        try hook(gate, ["hook_event_name": "Stop", "session_id": session(2)])
        try hook(limit, ["hook_event_name": "StopFailure", "session_id": session(3), "error": "rate_limit"])
        try rig.loam(["run", "stop", cancelled], extra: extra)

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        let model = host.model
        try await app.waitUntil("the runs load") { model.runs.count == 5 }
        try confirm(model.today.needsYouCount == 2, "Today counts \(model.today.needsYouCount) runs that need you")
        try await app.waitUntil("the Today row counts 2") { app.text(of: "sidebar-today")?.contains("2") == true }

        func appearance(_ name: NSAppearance.Name) async {
            NSApp.appearance = NSAppearance(named: name)
            await app.sleep(1)
        }

        // Today, from its sidebar row.
        try app.click("sidebar-today")
        try await app.waitUntil("Today shows") { model.page == .today && app.exists("today") }
        try confirm(app.exists("today-needs-you") && app.exists("today-line-\(plot)") && app.exists("today-line-\(other)"),
                    "Today has no Needs you section or line rows")
        try confirm(app.exists("run-row-\(gate)") && app.exists("run-row-\(cancelled)"), "a run row is missing")
        await appearance(.darkAqua)
        app.screenshot("today-night")
        await appearance(.aqua)
        app.screenshot("today-day")

        // The page of the run that the gate stopped: its note, its state, and its history.
        await appearance(.darkAqua)
        try app.click("run-row-\(gate)")
        try await app.waitUntil("the run page shows") {
            model.page == .run(gate) && model.runStatus?.run.id == gate && app.exists("run-page-history")
        }
        try confirm(app.text(of: "run-page-state")?.contains("Stopped") == true, "the state is \(app.text(of: "run-page-state") ?? "none")")
        try confirm(app.exists("run-page-note") && app.exists("run-page-watch"), "the note or Watch is missing")
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
}
