import AppKit
import Foundation
import LoamKit

@MainActor
extension Scenarios {
    static func intakeSetupShot(_ app: DriverApp) async throws {
        do { try await intakeSetupSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// TAS-74: the setup approval on the Intake page. The repo has a new setup command, so the core refuses the start
    /// of a chore. The start sheet then shows the command in full, because the next start approves that text by its hash. A press of the button then starts the run.
    private static func intakeSetupSteps(_ app: DriverApp) async throws {
        let (rig, environment, _) = try shotRig(app)
        let (repo, _) = try widgetsRepo(rig, onGitHub: false)
        let plot = try rig.newPlot("Checkout")
        try rig.loam(["repo", "add", plot, repo.path, "--setup", "test -f README.md"], extra: environment)
        // A command that you type is approved. A session sets one with update_repo, which approves nothing, so clear the approval.
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [rig.loamHome.appendingPathComponent("loam.db").path, "UPDATE repo_settings SET setup_approved = ''"]
        try sqlite.run()
        sqlite.waitUntilExit()
        let map = rig.root.appendingPathComponent("maps/build")
        try FileManager.default.createDirectory(at: map.appendingPathComponent("issues"), withIntermediateDirectories: true)
        try "# Build\n".write(to: map.appendingPathComponent("map.md"), atomically: true, encoding: .utf8)
        try "Status: open\n\n# Ticket 1\n\nThe text of ticket 1.\n"
            .write(to: map.appendingPathComponent("issues/1-ticket.md"), atomically: true, encoding: .utf8)
        try rig.loam(["link", "add", plot, "Build map", map.appendingPathComponent("map.md").path])

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        let model = host.model
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await model.showIntake(plot: plot)
        try await app.waitUntil("the intake shows the ticket") { app.exists("intake-row-map 1") }
        try app.click("intake-row-map 1")
        try await app.waitUntil("the chore button shows") { app.exists("intake-chore") }
        try app.click("intake-chore")
        try await app.waitUntil("the start sheet opens") { app.exists("intake-start-sheet") }
        try app.click("intake-start")
        try await app.waitUntil("the sheet shows the setup command") { app.exists("intake-start-setup") }
        try await app.waitUntil("the sheet shows this command") { model.runStartSetup?.command == "test -f README.md" }
        await app.sleep(0.5)
        app.screenshot("intake-setup-night")
        NSApp.appearance = NSAppearance(named: .aqua)
        await app.sleep(0.5)
        app.screenshot("intake-setup-day")
        NSApp.appearance = nil

        // The next start approves that text: the setup command runs, and the refusal is gone.
        try app.click("intake-start")
        // A start that fails keeps the sheet open, so only a run that started passes this wait.
        try await app.waitUntil("the run starts after the approval") { !model.isStartingRun && !app.exists("intake-start-sheet") }
    }
}
