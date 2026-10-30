import AppKit
import LoamKit

/// A landed or ended run of the history of the metrics shot, written into the store as `loam` writes it.
private struct PastRun {
    let id: String
    let title: String
    /// When the run was approved, in days before now.
    let daysAgo: Double
    /// Each state of the run, and the minutes from the state before. The first state is at the approval.
    let states: [(String, Double)]
    /// The failed gates of the run: the minutes after the approval, and the stage.
    var tries: [(Double, String)] = []
    var fixes = ""
}

@MainActor
extension Scenarios {
    private static func confirmMetrics(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func metricsShot(_ app: DriverApp) async throws {
        do { try await metricsShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// Writes the runs and their events into the store of the rig, with the times of the history.
    private static func writeHistory(_ rig: PanelRig, plot: String, runs: [PastRun]) throws {
        let now = Date().timeIntervalSince1970 * 1000
        var sql = ""
        for run in runs {
            let approved = now - run.daysAgo * 86_400_000
            var at = approved
            var events: [(Double, String, String, String)] = []
            for (state, minutes) in run.states {
                at += minutes * 60_000
                events.append((at, "state", state, ""))
            }
            for (minutes, stage) in run.tries { events.append((approved + minutes * 60_000, "try", "the gate failed", stage)) }
            events.sort { $0.0 < $1.0 }
            let state = run.states.last?.0 ?? "queued"
            let tries = run.tries.filter { $0.1 == "gate" }.count
            sql += """
            INSERT INTO runs (id, plot_id, folder, title, state, tries, max_tries, turns, fixes, created_at, updated_at)
            VALUES ('\(run.id)', '\(plot)', '\(rig.root.path)/runs/\(run.id)', '\(run.title)', '\(state)', \(tries), 3, 12,
                    '\(run.fixes)', \(Int(approved)), \(Int(at)));

            """
            for (at, kind, detail, stage) in events {
                sql += "INSERT INTO run_events (run_id, at, kind, detail, stage) VALUES "
                    + "('\(run.id)', \(Int(at)), '\(kind)', '\(detail)', '\(stage)');\n"
            }
        }
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [rig.loamHome.appendingPathComponent("loam.db").path, ".timeout 5000", sql]
        try sqlite.run()
        sqlite.waitUntilExit()
        if sqlite.terminationStatus != 0 { throw DriverFailure("sqlite3 exited \(sqlite.terminationStatus)") }
    }

    /// TAS-176: the Metrics page. Five runs landed in the last 30 days and one in the 30 days before. Most of the
    /// time is in Merge, one run needed a second gate, and a later run fixes it. The page shows the lead time by
    /// station, and a row of the slowest list opens its run. Fix this, on the page of the landed run, drafts a run
    /// that fixes it, and the desk shows the draft.
    private static func metricsShotSteps(_ app: DriverApp) async throws {
        let (rig, environment, _) = try shotRig(app)
        let (repo, _) = try widgetsRepo(rig, onGitHub: false)
        let plot = try rig.newPlot("Loam v1 build")
        try rig.loam(["repo", "add", plot, repo.path], extra: environment)
        let ship: [(String, Double)] = [("queued", 0), ("starting", 1), ("running", 0.5)]
        try writeHistory(rig, plot: plot, runs: [
            PastRun(id: "runmetrica", title: "Plot search matches link labels", daysAgo: 12,
                    states: [("shaping", 0), ("queued", 3), ("starting", 1), ("running", 0.5), ("shipping", 24),
                             ("ready", 5), ("landed", 98)]),
            PastRun(id: "runmetricb", title: "Desk keys type into the answer field", daysAgo: 9,
                    states: ship + [("shipping", 41), ("ready", 6), ("landed", 74)], tries: [(18, "gate")]),
            PastRun(id: "runmetricc", title: "Fix: Desk keys type into the answer field", daysAgo: 6,
                    states: ship + [("shipping", 12), ("ready", 4), ("landed", 61)], fixes: "runmetricb"),
            PastRun(id: "runmetricd", title: "A recurring run skips a sleeping Mac", daysAgo: 4,
                    states: ship + [("shipping", 33), ("ready", 9), ("landed", 312)]),
            PastRun(id: "runmetrice", title: "A toast says why a follow-up was not filed", daysAgo: 2,
                    states: ship + [("shipping", 19), ("ready", 5), ("landed", 88)]),
            PastRun(id: "runmetricf", title: "Group runs by repo on the desk", daysAgo: 3,
                    states: ship + [("cancelled", 26)]),
            PastRun(id: "runmetricg", title: "Sidebar counts match the pages", daysAgo: 40,
                    states: ship + [("shipping", 28), ("ready", 6), ("landed", 150)]),
        ])
        // claude -p prints the draft of the fix. Other calls do what they did.
        let draft = rig.root.appendingPathComponent("draft.json")
        try #"""
        {"type": "result", "subtype": "success", "is_error": false, "result": "",
         "structured_output": {
          "goal": "A recurring run that wakes a sleeping Mac waits for the next slot, and the run says why.",
          "checks": [{"name": "Recurring tests", "command": "go test ./internal/recurring/..."}],
          "assumptions": ["The run skips the slot when the Mac slept through it, as the landed run does."],
          "follow_ups": [],
          "plan": ["Read the wake time before the run starts.", "Add a test for a Mac that wakes after the slot."],
          "size": "About 40 lines in one package."}}
        """#.write(to: draft, atomically: true, encoding: .utf8)
        try printDraft(rig, draft)

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        frameLikeTheDesign(host.window)
        let model = host.model
        func appearance(_ name: NSAppearance.Name) async {
            NSApp.appearance = NSAppearance(named: name)
            await app.sleep(1)
        }

        // The sidebar row opens the page for every plot.
        await appearance(.darkAqua)
        try app.click("sidebar-metrics")
        try await app.waitUntil("the page shows the metrics") {
            model.page == .metrics && model.metrics != nil && app.exists("metrics-lead") && app.exists("metrics-bar")
        }
        guard let now = model.metrics?.current, let before = model.metrics?.previous else { throw DriverFailure("no metrics") }
        try confirmMetrics(now.landed == 5 && before.landed == 1 && now.fixed == 1 && now.notLanded.cancelled == 1,
                           "the metrics do not hold the history: \(now)")
        try confirmMetrics(MetricsWords.slowestStation(now)?.name == "Merge" && now.recovery.gate.count == 1,
                           "Merge is not the slowest station, or the gate recovery is missing: \(now.stations)")
        try confirmMetrics(now.slowest.first?.runID == "runmetricd", "the slowest run is not first: \(now.slowest)")
        await app.sleep(0.5)
        app.screenshot("metrics-night")

        // A row of the slowest list opens the landed run, and Fix this drafts a run that fixes it.
        try app.click("metrics-slow-runmetricd")
        try await app.waitUntil("the run page shows the landed run") {
            model.page == .run("runmetricd") && model.runStatus?.run.id == "runmetricd" && app.exists("run-page-fix")
        }
        await app.sleep(0.5)
        app.screenshot("metrics-run-fix-night")
        try app.click("run-page-fix")
        try await app.waitUntil("the desk shows the draft of the fix", timeout: 30) {
            model.page == .desk && app.exists("desk-shape")
                && model.runs.contains { $0.state == .shaping && $0.fixes == "runmetricd" }
        }
        let fix = model.runs.first { $0.fixes == "runmetricd" }
        try confirmMetrics(fix?.title == "Fix: A recurring run skips a sleeping Mac" && model.fixError == nil,
                           "the fix is not drafted as Fix this asks: \(String(describing: fix))")
        await app.sleep(0.5)
        app.screenshot("metrics-fix-desk-night")
        NSApp.appearance = nil
    }
}
