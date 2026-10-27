import AppKit
import LoamKit
import LoamTerminal

@MainActor
extension Scenarios {
    static func recurringShot(_ app: DriverApp) async throws {
        do { try await recurringShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// Ticket 208: the Recurring page. A chore whose precheck found no work was skipped, and the Intake page opens
    /// the Recurring page of the plot. A new Shape run is filled into the form and added. Run now drafts a run, and
    /// the agent switch installs the launchd agent (a stand-in launchctl).
    private static func recurringShotSteps(_ app: DriverApp) async throws {
        let (rig, shotEnvironment, _) = try shotRig(app)
        let environment = shotEnvironment.merging(["LOAM_LAUNCHCTL": "/usr/bin/true"]) { $1 }
        let (repo, _) = try widgetsRepo(rig, onGitHub: false)
        let plot = try rig.newPlot("Loam v1 build")
        try rig.loam(["repo", "add", plot, repo.path], extra: environment)
        let draft = rig.root.appendingPathComponent("draft.json")
        try #"""
        {"type": "result", "subtype": "success", "is_error": false, "result": "",
         "structured_output": {"goal": "Each new bug has a driver scenario that shows it.",
          "checks": [{"name": "Driver", "command": "swift test --filter DriverTests"}],
          "assumptions": ["A bug that the driver cannot show gets a note, not a scenario."],
          "plan": ["Read the new bugs.", "Write a scenario for each."], "size": "About 40 lines a bug."}}
        """#.write(to: draft, atomically: true, encoding: .utf8)
        try printDraft(rig, draft)
        let added = try rig.loam(["recurring", "add", plot, "--title", "Bump Go dependencies",
                                  "--prompt", "Bump the Go modules that have updates.", "--kind", "chore", "--days", "daily",
                                  "--at", "02:00", "--precheck", "go list -m -u all | grep -q '\\['", "--json"], extra: environment)
        guard let chore = ((try JSONSerialization.jsonObject(with: Data(added.utf8)) as? [String: Any])?["recurring"]
            as? [String: Any])?["id"] as? String else {
            throw DriverFailure("recurring add printed no recurring run: \(added)")
        }
        // A tick far ahead: the chore is due, and its precheck finds no work in a folder with no Go module.
        try rig.loam(["tick", "--now", "2099-01-01T12:00:00Z"], extra: environment)

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        let model = host.model
        func appearance(_ name: NSAppearance.Name) async {
            NSApp.appearance = NSAppearance(named: name)
            await app.sleep(1)
        }
        await appearance(.darkAqua)
        await model.showIntake(plot: plot)
        try await app.waitUntil("the intake shows") { app.exists("intake-recurring") }
        try app.click("intake-recurring")
        try await app.waitUntil("the page lists the chore") {
            model.page == .recurring(plot) && app.exists("recurring-\(chore)") && model.tickStatus != nil
        }
        try confirm(model.recurring.first?.lastNote.contains("found no work") == true,
                    "the chore did not skip: \(model.recurring.first?.lastNote ?? "")")

        // A new Shape run, typed.
        try app.fill("recurring-title", with: "Shape new bugs")
        try app.fill("recurring-prompt", with: "Read new GitHub issues labelled bug. For each one, try to reproduce it with a driver scenario.")
        try await app.waitUntil("the form is filled") { AccessibilityProbe.shared.isEnabled("recurring-add") }
        await app.sleep(0.5)
        app.screenshot("recurring-form-night")
        try app.click("recurring-add")
        try await app.waitUntil("the Shape run is added") { model.recurring.count == 2 && model.recurringError == nil }
        let shape = try unwrap(model.recurring.first { $0.title == "Shape new bugs" }, "the new recurring run")
        try confirm(shape.kind == .shape && shape.days == ["mon", "tue", "wed", "thu", "fri"] && shape.at == "07:00",
                    "the new recurring run is \(shape)")

        // Run now drafts a run, which waits at the desk.
        try app.click("recurring-run-\(shape.id)")
        try await app.waitUntil("Run now drafts a run") {
            model.runs.contains { $0.state == .shaping && $0.source?.key == shape.id }
                && model.recurring.first { $0.id == shape.id }?.lastAt != nil
        }

        // The switch installs the launchd agent.
        try app.click("recurring-agent")
        try await app.waitUntil("the agent is installed") { model.tickStatus?.installed == true }
        await app.sleep(0.5)
        app.screenshot("recurring-night")
        await appearance(.aqua)
        app.screenshot("recurring-day")
        NSApp.appearance = nil
    }

    private static func confirm(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    private static func unwrap<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw DriverFailure("no \(what)") }
        return value
    }
}
