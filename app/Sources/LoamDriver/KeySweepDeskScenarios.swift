import AppKit
import LoamKit
import LoamTerminal

/// The key sweep of a run that is ready: the desk with its diff, the PR popover and the Land sheet. Run it with
/// `LOAM_DRIVER_FOREGROUND=1` and `LOAM_DRIVER_FAKE_GH`.
@MainActor
extension Scenarios {
    static func keySweepDesk(_ app: DriverApp) async throws {
        do { try await keySweepDeskSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func keySweepDeskSteps(_ app: DriverApp) async throws {
        let gh = try GitHubRun(app, title: "Plot search matches link labels", goal: "A search for a link label finds its plot.")
        try FileManager.default.createDirectory(at: gh.folder.appendingPathComponent("search"), withIntermediateDirectories: true)
        try "package search\n\nfunc TestMatchLabels(t *testing.T) {}\n"
            .write(to: gh.folder.appendingPathComponent("search/match_test.go"), atomically: true, encoding: .utf8)
        try git(gh.folder, ["add", "search/match_test.go"])
        try gh.commitAndStop("search/match.go", text: (1...12).map { "// line \($0)" }.joined(separator: "\n") + "\n")
        let host = try await app.launchApp(
            client: LoamClient(binary: gh.rig.binary, environment: gh.environment), state: gh.rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        frameLikeTheDesign(host.window)
        let model = host.model
        let sweep = try KeySweep(app)
        try await sweep.makeKey(host.window, "the main window")
        try await app.waitUntil("the run ships") { model.runs.first?.state == .shipping }
        await model.tickRuns()
        try gh.setCI("SUCCESS")
        await model.tickRuns()
        try await app.waitUntil("the run is ready") { model.runs.first?.state == .ready }

        try await sweep.click("sidebar-today")
        try await app.waitUntil("Today shows") { model.page == .today }
        await sweep.check("Today", "⌘↩ Open the desk", "\r", .command) { model.page == .desk }
        if model.page != .desk { await model.openDesk() }
        try await app.waitUntil("the desk shows the diff") { app.exists("desk-file-search/match.go") && app.exists("desk-line-8") }
        await app.sleep(0.5)
        let d = "Desk Review"
        sweep.note("Desk: keys \(sweep.holder)")
        let file = model.desk.file
        await sweep.check(d, "] Next file", "]") { model.desk.file != file }
        await sweep.check(d, "] Next file goes round", "]") { model.desk.file == file }
        await sweep.check(d, "Esc Leave the desk", "\u{1B}") { model.page == .today }
        if model.page != .desk { await model.openDesk() }
        try await app.waitUntil("the desk shows the diff again") { app.exists("desk-line-8") }
        await app.sleep(0.5)

        // A click on Cancel closes a note, and the desk keys work after it.
        try await sweep.click("desk-line-5")
        try? await app.waitUntil("the note field on line 5 has the keys", timeout: 3) { app.fieldWithTheKeys() == "Note on line 5" }
        try await sweep.click("desk-note-cancel")
        await app.sleep(0.3)
        let f0 = model.desk.file
        await sweep.check(d, "] after a click on Cancel", "]") { model.desk.file != f0 }
        if model.desk.file != f0 { await sweep.check(d, "] back", "]") { model.desk.file == f0 } }
        // A second click on the line closes the note. A click on another line moves it, and Esc closes it there.
        try await sweep.click("desk-line-6")
        try? await app.waitUntil("the note field on line 6 has the keys", timeout: 3) { app.fieldWithTheKeys() == "Note on line 6" }
        try await sweep.click("desk-line-6")
        try? await app.waitUntil("the note on line 6 closes", timeout: 3) { !app.exists("desk-note-field") }
        let f1 = model.desk.file
        await sweep.check(d, "] after a second click on the line", "]") { model.desk.file != f1 }
        if model.desk.file != f1 { await sweep.check(d, "] back", "]") { model.desk.file == f1 } }
        try await sweep.click("desk-line-6")
        try? await app.waitUntil("the note field on line 6 has the keys", timeout: 3) { app.fieldWithTheKeys() == "Note on line 6" }
        try await sweep.click("desk-line-7")
        try? await app.waitUntil("the note field moves to line 7", timeout: 3) { app.fieldWithTheKeys() == "Note on line 7" }
        sweep.expect(d, "A click on another line moves the note field", app.fieldWithTheKeys() == "Note on line 7")
        await sweep.check(d, "Esc closes the moved note", "\u{1B}") { !app.exists("desk-note-field") }
        let f2 = model.desk.file
        await sweep.check(d, "] after the moved note closes", "]") { model.desk.file != f2 }
        if model.desk.file != f2 { await sweep.check(d, "] back", "]") { model.desk.file == f2 } }

        // A note on line 8: ↩ saves it. Esc cancels a note on line 3.
        try await sweep.click("desk-line-8")
        try? await app.waitUntil("the note field has the keys", timeout: 3) { app.fieldWithTheKeys() == "Note on line 8" }
        sweep.note("note field: keys \(sweep.holder)")
        await sweep.type("Match repos too")
        await sweep.check(d, "↩ Save note", "\r") { app.exists("desk-note-8") && model.desk.currentNotes.count == 1 }
        if model.desk.currentNotes.isEmpty, app.exists("desk-note-save") { try app.click("desk-note-save") }
        sweep.note("after the note: keys \(sweep.holder)")
        let saved = model.desk.file
        await sweep.check(d, "] after ↩ saves a note", "]") { model.desk.file != saved }
        if model.desk.file != saved { await sweep.check(d, "] back", "]") { model.desk.file == saved } }
        // A click on another file while a note field has the keys closes the note.
        try await sweep.click("desk-line-6")
        try? await app.waitUntil("the note field on line 6 has the keys", timeout: 3) { app.fieldWithTheKeys() == "Note on line 6" }
        try await sweep.click("desk-file-search/match_test.go")
        try? await app.waitUntil("the other file shows", timeout: 3) { model.desk.file == "search/match_test.go" }
        sweep.expect(d, "A click on another file closes the note", !app.exists("desk-note-field"))
        let f3 = model.desk.file
        await sweep.check(d, "] after a click on another file with a note open", "]") { model.desk.file != f3 }
        try await sweep.click("desk-file-search/match.go")
        await app.sleep(0.3)
        let clickedFile = model.desk.file
        sweep.note("after a click on the file tab: file \(clickedFile ?? "nil"), keys \(sweep.holder)")
        await sweep.check(d, "] after a click on a file", "]") { model.desk.file != clickedFile }
        if model.desk.file != clickedFile { await sweep.check(d, "] back", "]") { model.desk.file == clickedFile } }
        try await sweep.click("desk-line-3")
        try? await app.waitUntil("the note field on line 3 has the keys", timeout: 3) { app.fieldWithTheKeys() == "Note on line 3" }
        await sweep.check(d, "Esc cancels the note", "\u{1B}") { !app.exists("desk-note-field") }
        await app.sleep(0.3)
        let afterEsc = model.desk.file
        await sweep.check(d, "] after Esc closes a note", "]") { model.desk.file != afterEsc }

        // The PR popover and the Land sheet of the worktree.
        if let worktree = model.runs.first?.worktreeID, !worktree.isEmpty {
            model.closePage()
            await app.sleep(0.5)
            if model.openPullRequest(worktree) {
                try? await app.waitUntil("the PR popover shows", timeout: 3) { model.prPopover.isOpen }
                await app.sleep(0.5)
                sweep.note("PR popover: keys \(sweep.holder)")
                await sweep.check("PR popover", "Esc closes", "\u{1B}") { !model.prPopover.isOpen }
            } else { sweep.note("the PR popover did not open") }
            if model.openLandSheet(worktree) {
                try? await app.waitUntil("the Land sheet shows", timeout: 3) { model.landSheet.isOpen }
                await app.sleep(0.8)
                sweep.note("Land sheet: keys \(sweep.holder)")
                await sweep.check("Land sheet", "Esc closes", "\u{1B}") { !model.landSheet.isOpen }
            } else { sweep.note("the Land sheet did not open") }
            await model.openDesk()
            try await app.waitUntil("the desk shows the diff again") { app.exists("desk-line-8") }
            await app.sleep(0.5)
        } else {
            sweep.note("the run has no worktree")
        }

        // S sends the note back.
        try? await app.waitUntil("the note is still there", timeout: 2) { model.desk.currentNotes.count == 1 }
        await sweep.check(d, "S Send back", "s", timeout: 5) { model.runs.first?.state == .running }
        if model.runs.first?.state != .running { try? app.click("desk-send-back") }
        try await app.waitUntil("the run runs again") { model.runs.first?.state == .running }
        try gh.commitAndStop("search/repo.go", text: "package search\n")
        await model.reloadRuns()
        await model.tickRuns()
        try gh.setCI("SUCCESS")
        await model.tickRuns()
        try await app.waitUntil("the run is ready again") { model.runs.first?.state == .ready }
        await model.openDesk()
        try await app.waitUntil("Merge shows") { app.exists("desk-merge") && model.desk.diff != nil }
        await app.sleep(0.5)
        sweep.note("Merge: keys \(sweep.holder)")
        await sweep.check(d, "⌘↩ Merge", "\r", .command, timeout: 8) { model.runs.first?.state == .landed }
        try sweep.summary()
    }
}
