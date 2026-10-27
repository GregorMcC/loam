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

    static func ruleShot(_ app: DriverApp) async throws {
        do { try await ruleShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// Ticket 209: rules. An earlier run had the note "Keep the README short" sent back. A second run stops at the
    /// desk, and you send back a note like it. The desk offers a rule, and Add rule adds it with its command,
    /// typed. The Recurring page lists the rule of the plot.
    private static func ruleShotSteps(_ app: DriverApp) async throws {
        let (rig, environment, _) = try shotRig(app)
        let (repo, _) = try widgetsRepo(rig, onGitHub: false)
        let plot = try rig.newPlot("Loam v1 build")
        try rig.loam(["repo", "add", plot, repo.path], extra: environment)
        /// A run whose one check fails, so its first stop stops it.
        func stoppedRun(_ title: String) throws -> String {
            let text = try rig.loam(["run", "start", plot, "--title", title, "--check", "Guide=test -f GUIDE.md",
                                     "--max-tries", "1", "--json"], extra: environment)
            guard let id = ((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["run"]
                as? [String: Any])?["id"] as? String else {
                throw DriverFailure("run start printed no run: \(text)")
            }
            for event in ["SessionStart", "Stop"] {
                try rig.loam(["run", "hook", id], extra: environment,
                             input: #"{"hook_event_name": "\#(event)", "session_id": "\#(GitHubRun.session)"}"#)
            }
            return id
        }
        let earlier = try stoppedRun("Tidy the README")
        try rig.loam(["run", "send-back", earlier, "--note", "README.md:3: Keep the README short."], extra: environment)
        try rig.loam(["run", "stop", earlier], extra: environment)
        let id = try stoppedRun("Write the guide")

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        let model = host.model
        func appearance(_ name: NSAppearance.Name) async {
            NSApp.appearance = NSAppearance(named: name)
            await app.sleep(1)
        }
        await appearance(.darkAqua)
        try await app.waitUntil("the run is stopped") { model.runs.contains { $0.id == id && $0.state == .stopped } }
        await model.openDesk(id)
        try await app.waitUntil("the desk shows the run") { model.desk.runID == id && app.exists("desk-run-note-field") }

        // A note on the whole run goes back. It is like the earlier note, so the desk offers a rule.
        model.addDeskNote(file: nil, line: nil, text: "Keep the README short, please. One screen at most.")
        try await app.waitUntil("Send back is on") { AccessibilityProbe.shared.isEnabled("desk-send-back") }
        try app.click("desk-send-back")
        try await app.waitUntil("the desk offers a rule") { model.desk.ruleOffer != nil && app.exists("desk-rule-offer") }
        try confirm(model.desk.ruleOffer?.offer.earlier == "Keep the README short.",
                    "the offer is \(String(describing: model.desk.ruleOffer))")
        try app.fill("desk-rule-command", with: "test $(wc -l < README.md) -lt 40")
        try await app.waitUntil("Add rule is on") { AccessibilityProbe.shared.isEnabled("desk-rule-add") }
        await app.sleep(0.5)
        app.screenshot("rule-offer-night")
        await appearance(.aqua)
        app.screenshot("rule-offer-day")
        await appearance(.darkAqua)
        try app.click("desk-rule-add")
        try await app.waitUntil("the rule is added") { model.desk.ruleOffer == nil && !app.exists("desk-rule-offer") }

        // The Recurring page lists the rule.
        await model.showRecurring(plot: plot)
        try await app.waitUntil("the page lists the rule") { model.rules.count == 1 && app.exists("rule-\(model.rules[0].id)") }
        try confirm(model.rules[0].name == "Keep the README short" && model.rules[0].note.hasPrefix("Keep the README short, please."),
                    "the rule is \(model.rules[0])")
        await app.sleep(0.5)
        app.screenshot("rules-night")
        await appearance(.aqua)
        app.screenshot("rules-day")
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
