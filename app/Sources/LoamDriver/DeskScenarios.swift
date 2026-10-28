import AppKit
import LoamKit
import LoamTerminal

/// A run in a repo on GitHub, for the scenarios of tickets 206 and 207. The fake gh (`LOAM_DRIVER_FAKE_GH`)
/// stands in for GitHub, and the scenario writes its state. The origin is a local bare repo behind a fake ssh.
@MainActor
struct GitHubRun {
    static let session = "c57ef956-3136-4e86-bfde-da8facfe0523"

    let rig: PanelRig
    /// The environment of the app and of each `loam` call: the shot rig, the fake gh, and the fake ssh.
    let environment: [String: String]
    let plot: String
    let id: String
    let folder: URL
    let ghState: URL

    /// Starts the run in a new plot with one check that passes, and sends the SessionStart hook.
    init(_ app: DriverApp, title: String, goal: String) throws {
        guard let fakeGH = ProcessInfo.processInfo.environment["LOAM_DRIVER_FAKE_GH"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_GH does not name the fake gh")
        }
        let (rig, shotEnvironment, _) = try Scenarios.shotRig(app)
        let (repo, ssh) = try Scenarios.widgetsRepo(rig, onGitHub: true)
        ghState = rig.root.appendingPathComponent("gh-state.json")
        try "{}".write(to: ghState, atomically: true, encoding: .utf8)
        environment = shotEnvironment.merging([
            "LOAM_GH": fakeGH, "LOAM_FAKE_GH_STATE": ghState.path,
            "LOAM_FAKE_GH_LOG": rig.root.appendingPathComponent("gh-calls.jsonl").path,
            "GIT_SSH_COMMAND": ssh,
        ]) { $1 }
        plot = try rig.newPlot("Loam v1 build")
        // The fake ssh serves the fetch of repo add, so it does not reach GitHub.
        try rig.loam(["repo", "add", plot, repo.path], extra: environment)
        let text = try rig.loam(["run", "start", plot, "--title", title, "--goal", goal, "--check", "Tests=true", "--json"],
                                extra: environment)
        let object = (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["run"] as? [String: Any]
        guard let id = object?["id"] as? String, let folder = (object?["folder"] as? String).map(URL.init(fileURLWithPath:)) else {
            throw DriverFailure("run start printed no run: \(text)")
        }
        (self.rig, self.id, self.folder) = (rig, id, folder)
        try rig.loam(["run", "hook", id], extra: environment,
                     input: #"{"hook_event_name": "SessionStart", "session_id": "\#(Self.session)", "source": "startup"}"#)
    }

    /// Writes a file in the worktree and commits it, as the session does, and ends the turn. The gate passes.
    func commitAndStop(_ name: String, text: String? = nil) throws {
        let file = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text ?? "\(name)\n").write(to: file, atomically: true, encoding: .utf8)
        try Scenarios.git(folder, ["add", name])
        try Scenarios.git(folder, ["commit", "-q", "-m", "Change \(name)"])
        try rig.loam(["run", "hook", id], extra: environment,
                     input: #"{"hook_event_name": "Stop", "session_id": "\#(Self.session)"}"#)
    }

    /// GitHub with PR #1 at the head of the worktree, and one check, ci / test, with the conclusion. The repo
    /// squashes by default, and the PR is up to date with main, so a passed PR can merge.
    func setCI(_ conclusion: String) throws {
        let head = try Scenarios.git(folder, ["rev-parse", "HEAD"])
        let branch = try Scenarios.git(folder, ["branch", "--show-current"])
        try """
        {"refs": ["\(branch)"],
         "pulls": [{"number": 1, "title": "Plot search matches link labels", "url": "https://github.com/example/widgets/pull/1",
           "state": "OPEN", "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "baseRefName": "main",
           "headRefName": "\(branch)", "headRefOid": "\(head)", "commits": {"totalCount": 2}}],
         "details": {"1": {"baseRef": {"compare": {"behindBy": 0}}, "reviewThreads": {"nodes": []},
           "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "\(conclusion)",
           "contexts": {"totalCount": 1, "nodes": [{"__typename": "CheckRun", "name": "test", "status": "COMPLETED",
           "conclusion": "\(conclusion)", "isRequired": true,
           "checkSuite": {"workflowRun": {"databaseId": 9001, "workflow": {"name": "ci"}}}}]}}}}]}}},
         "repository": {"mergeCommitAllowed": false, "squashMergeAllowed": true, "rebaseMergeAllowed": false,
           "viewerDefaultMergeMethod": "SQUASH"},
         "logs": {"9001": "test\\tgo test\\t--- FAIL: TestSearchLabels (0.00s)\\ntest\\tgo test\\tFAIL\\n"}}
        """.write(to: ghState, atomically: true, encoding: .utf8)
    }
}

@MainActor
extension Scenarios {
    private static func confirmDesk(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func deskShot(_ app: DriverApp) async throws {
        do { try await deskShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// Ticket 207: the desk. A run whose CI passed waits on the Land tile. The tile opens the desk on the run,
    /// with its diff by file. A click on a line number opens a note, and Send back resumes the session with it.
    /// The change comes back through the gate and CI, and Merge lands the run.
    private static func deskShotSteps(_ app: DriverApp) async throws {
        let gh = try GitHubRun(app, title: "Plot search matches link labels", goal: "A search for a link label finds its plot.")
        // Two files, so ] has a next file while you type a note.
        try FileManager.default.createDirectory(at: gh.folder.appendingPathComponent("search"), withIntermediateDirectories: true)
        try "package search\n\nfunc TestMatchLabels(t *testing.T) {}\n"
            .write(to: gh.folder.appendingPathComponent("search/match_test.go"), atomically: true, encoding: .utf8)
        try git(gh.folder, ["add", "search/match_test.go"])
        try gh.commitAndStop("search/match.go", text: """
        package search

        // Match returns the items whose title or link label matches q.
        func Match(q string, items []Item) []Result {
        \tvar out []Result
        \tfor _, it := range items {
        \t\tscore := Score(q, it.Title)
        \t\tif score == 0 && it.Kind == KindLink {
        \t\t\tscore = Score(q, it.Label) * labelWeight
        \t\t}
        \t\tif score > 0 {
        \t\t\tout = append(out, Result{Item: it, Score: score})
        \t\t}
        \t}
        \treturn out
        }

        // labelWeight keeps a title match above a label match.
        const labelWeight = 0.8

        """)
        // claude -p writes the ship notes when Loam opens the PR, as claude -p --output-format json does.
        let notes = gh.rig.root.appendingPathComponent("ship-notes.json")
        try #"""
        {"type": "result", "subtype": "success", "is_error": false, "result": "",
         "structured_output": {
          "walkthrough": "Search now matches the label of a link when its title does not match. A label scores lower than a title, so a title match still comes first.",
          "files": [{"path": "search/match.go", "role": "The rule"}, {"path": "search/match_test.go", "role": "Tests"}],
          "risk": {"level": "low", "reasons": ["2 files, all in the search package. No store change. No new dependency."]},
          "where_it_stands": "Plot search matches link labels. A title match still ranks first."}}
        """#.write(to: notes, atomically: true, encoding: .utf8)
        try printDraft(gh.rig, notes)
        let host = try await app.launchApp(
            client: LoamClient(binary: gh.rig.binary, environment: gh.environment), state: gh.rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        frameLikeTheDesign(host.window)
        let model = host.model
        try await app.waitUntil("the run ships") { model.runs.first?.state == .shipping }
        await model.tickRuns()
        try gh.setCI("SUCCESS")
        await model.tickRuns()
        try await app.waitUntil("the run is ready") { model.runs.first?.state == .ready }
        func appearance(_ name: NSAppearance.Name) async {
            NSApp.appearance = NSAppearance(named: name)
            await app.sleep(1)
        }

        // TAS-45: a run that is ready to land is done, unread, and the Today row counts it. A click on Done, unread opens
        // the desk on it, since no pane is done, unread.
        await appearance(.darkAqua)
        try await app.waitUntil("Done, unread counts the run") {
            app.text(of: "attention-done-unread")?.contains("1") == true && app.text(of: "sidebar-today")?.contains("1") == true
        }
        app.screenshot("done-unread-run")
        try app.click("attention-done-unread")
        try await app.waitUntil("Done, unread opens the desk") { model.page == .desk && model.desk.runID == gh.id }

        // The Land tile opens the desk on the run, with its diff.
        try app.click("sidebar-today")
        try await app.waitUntil("Today shows") { model.page == .today && app.exists("today-tile-land") }
        try app.click("today-tile-land")
        try await app.waitUntil("the desk shows the diff") {
            model.page == .desk && model.desk.runID == gh.id && app.exists("desk-file-search/match.go") && app.exists("desk-line-8")
        }
        // The ship notes give the order of the files, the walkthrough, and the risk.
        try confirmDesk(model.runs.first?.notes?.files.first?.role == "The rule" && app.exists("desk-walkthrough")
                        && app.exists("desk-risk") && app.exists("desk-where-it-stands"),
                        "the desk shows no ship notes: \(String(describing: model.runs.first?.notes))")

        // ] shows the next file, and after the last file the first one again (TAS-49).
        try app.pressShortcut(letter: "]")
        try await app.waitUntil("] shows the next file") { model.desk.file == "search/match_test.go" }
        try app.pressShortcut(letter: "]")
        try await app.waitUntil("] goes round to the first file") { model.desk.file == "search/match.go" }
        try app.pressShortcut(letter: "]")
        try await app.waitUntil("] shows the next file again") { model.desk.file == "search/match_test.go" }

        // A note on line 8, typed. The keys of the desk (j, k, and ]) type into the note, and the desk stays.
        try app.click("desk-file-search/match.go")
        try app.click("desk-line-8")
        try await app.waitUntil("the note field has the keys") { app.fieldWithTheKeys() == "Note on line 8" }
        let note = "Repos have labels too [like links]. Make it match them, just once."
        try app.type(note)
        try await app.waitUntil("the note is typed") { AccessibilityProbe.shared.node("desk-note-field")?.value == note }
        try confirmDesk(model.desk.file == "search/match.go", "a key moved the desk to \(model.desk.file ?? "no file")")
        try await app.waitUntil("Save is on") { AccessibilityProbe.shared.isEnabled("desk-note-save") }
        try app.click("desk-note-save")
        try await app.waitUntil("the note shows") { app.exists("desk-note-8") && model.desk.currentNotes.count == 1 }

        // Esc in a note cancels the note, and the desk stays.
        try app.click("desk-line-3")
        try await app.waitUntil("the note field on line 3 has the keys") { app.fieldWithTheKeys() == "Note on line 3" }
        app.press(.escape)
        try await app.waitUntil("Esc cancels the note") { !app.exists("desk-note-field") }
        try confirmDesk(model.page == .desk && model.desk.currentNotes.count == 1, "Esc left the desk or lost a note")
        await app.sleep(0.5)
        app.screenshot("desk-land-night")
        await appearance(.aqua)
        app.screenshot("desk-land-day")
        await appearance(.darkAqua)

        // Send back resumes the session with the note. Nothing else waits, so the desk is empty.
        try app.click("desk-send-back")
        try await app.waitUntil("the run runs again") {
            model.runs.first?.state == .running && model.runs.first?.note == "Sent back with 1 note" && app.exists("desk-empty")
        }
        try confirmDesk(model.desk.notes.isEmpty, "the notes stayed: \(model.desk.notes)")

        // The change passes the gate, goes to #1, and CI passes. The run is back on the Land tile.
        try gh.commitAndStop("search/repo.go", text: "package search\n\n// Repos match by label too.\n")
        await model.reloadRuns()
        await model.tickRuns()
        try gh.setCI("SUCCESS")
        await model.tickRuns()
        try await app.waitUntil("the run is ready again") { model.runs.first?.state == .ready }
        await model.openDesk()
        try await app.waitUntil("the desk shows the run") { app.exists("desk-merge") && model.desk.diff?.files.count == 3 }
        app.screenshot("desk-merge-night")

        // Merge lands the run, and the desk is empty.
        try app.click("desk-merge")
        try await app.waitUntil("the run lands") { model.runs.first?.state == .landed && app.exists("desk-empty") }
        try confirmDesk(model.runs.first?.note == "Merged #1 with squash", "the note is \(model.runs.first?.note ?? "")")
        app.screenshot("desk-empty-night")
        NSApp.appearance = nil
    }

    /// Sizes the window as the design frames of the desk are: 1440 by 900, or the screen when it is smaller.
    static func frameLikeTheDesign(_ window: NSWindow) {
        let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1440, screen.width), height = min(900, screen.height)
        window.setFrame(NSRect(x: screen.minX, y: screen.maxY - height, width: width, height: height), display: true)
    }

    /// Makes the claude of the shot rig print the file for claude -p, as claude -p --output-format json prints a
    /// draft. Other calls do what they did.
    static func printDraft(_ rig: PanelRig, _ draft: URL) throws {
        let claude = rig.root.appendingPathComponent("bin/claude")
        let stub = try String(contentsOf: claude, encoding: .utf8).replacingOccurrences(of: "#!/bin/sh\n", with: "")
        try "#!/bin/sh\nfor a in \"$@\"; do [ \"$a\" = -p ] && exec cat '\(draft.path)'; done\n\(stub)"
            .write(to: claude, atomically: true, encoding: .utf8)
    }

    static func shapeShot(_ app: DriverApp) async throws {
        do { try await shapeShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// Ticket 207: Shape. Claude drafts a run from a map ticket, and the run waits on the Shape tile. The tile
    /// opens the desk on the draft. You change an assumption, typed, and the keys of the desk type into the field.
    /// A approves the run, which starts with your change, and the desk is empty.
    private static func shapeShotSteps(_ app: DriverApp) async throws {
        let (rig, environment, _) = try shotRig(app)
        let (repo, _) = try widgetsRepo(rig, onGitHub: false)
        let plot = try rig.newPlot("Loam v1 build")
        // The repo has a setup command, so the approval approves it.
        try rig.loam(["repo", "add", plot, repo.path, "--setup", "test -f README.md"], extra: environment)
        // claude -p prints the draft, as claude -p --output-format json does. Other calls do what they did.
        let draft = rig.root.appendingPathComponent("draft.json")
        try #"""
        {"type": "result", "subtype": "success", "is_error": false, "result": "",
         "structured_output": {
          "goal": "A search for a link label finds its plot, and a title match ranks above a label match.",
          "checks": [{"name": "Search tests", "command": "go test ./search/..."}, {"name": "Vet", "command": "go vet ./... && go test -race -count=1 -run 'TestSearch(Label|Title)Order' ./search/... ./internal/plotsearch/..."}],
          "assumptions": ["A label match counts for less than a title match, so titles stay first.",
                          "Repos have labels too, and the search matches them the same way."],
          "plan": ["Score the label of a link when its title does not match.", "Weight a label match below a title match.",
                   "Add tests for a label match and for the order of the results."],
          "size": "About 80 lines in one package."}}
        """#.write(to: draft, atomically: true, encoding: .utf8)
        try printDraft(rig, draft)
        let ticket = rig.root.appendingPathComponent("issues/12-plot-search-labels.md")
        try FileManager.default.createDirectory(at: ticket.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Plot search matches link labels\n\nA search for the label of a link finds its plot.\n"
            .write(to: ticket, atomically: true, encoding: .utf8)
        try rig.loam(["run", "shape", plot, "--title", "Plot search matches link labels", "--ticket", ticket.path, "--json"],
                     extra: environment)

        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        frameLikeTheDesign(host.window)
        let model = host.model
        func appearance(_ name: NSAppearance.Name) async {
            NSApp.appearance = NSAppearance(named: name)
            await app.sleep(1)
        }

        // The Shape tile opens the desk on the draft.
        await appearance(.darkAqua)
        try app.click("sidebar-today")
        try await app.waitUntil("the Shape tile counts the draft") {
            model.page == .today && model.runs.first?.shape?.isDrafted == true && AccessibilityProbe.shared.isEnabled("today-tile-shape")
        }
        try app.click("today-tile-shape")
        try await app.waitUntil("the desk shows the draft") {
            model.page == .desk && app.exists("desk-shape") && app.exists("desk-assumption-1") && app.exists("desk-plan")
                && app.exists("desk-setup") && app.exists("desk-queue-\(model.desk.runID ?? "")")
        }
        await app.sleep(0.5)
        // The second check command is wider than the "If you approve" column, and the column still holds the gate.
        func frame(_ id: String) throws -> CGRect {
            try AccessibilityProbe.shared.node(id)?.frame ?? { throw DriverFailure("no frame for \(id)") }()
        }
        let (column, rows, gate) = try (frame("desk-if-you-approve"), frame("desk-approve-rows"), frame("desk-gate"))
        try confirmDesk(column.width <= 321, "the column is \(column.width) pt wide, not 320")
        try confirmDesk(column.insetBy(dx: -1, dy: -1).contains(rows), "the rows go past the column: \(column) \(rows)")
        try confirmDesk(column.minX - 1 <= gate.minX && gate.maxX <= column.maxX + 1,
                        "the gate goes past the column: \(column) \(gate)")
        app.screenshot("desk-shape-night")
        await appearance(.aqua)
        app.screenshot("desk-shape-day")
        await appearance(.darkAqua)

        // Change the second assumption, typed. A, C, N, J and K type into the field, and the desk stays.
        try app.click("desk-assumption-change-1")
        try await app.waitUntil("the field has the keys") { app.fieldWithTheKeys() == "Change assumption 2" }
        let answer = "No: a repo has no labels, so only links match."
        try app.type(answer)
        try await app.waitUntil("the answer is typed") { AccessibilityProbe.shared.node("desk-assumption-field")?.value == answer }
        try confirmDesk(model.page == .desk && model.runs.first?.state == .shaping, "a key acted on the desk while you typed")
        app.press(.returnKey)
        try await app.waitUntil("the answer shows") {
            app.exists("desk-assumption-answer-1") && model.desk.currentEdit.answers == [1: answer]
        }
        await app.sleep(0.5)
        app.screenshot("desk-shape-changed-night")

        // A approves the run. It starts with your change, and nothing else waits.
        try app.type("a")
        try await app.waitUntil("the run starts") {
            model.runs.first.map { $0.state != .shaping } == true && app.exists("desk-empty")
        }
        let run = model.runs.first
        try confirmDesk(run?.shape?.assumptions.last?.answer == answer && run?.worktreeID.isEmpty == false,
                        "the run started without the change: \(String(describing: run))")
        NSApp.appearance = nil
    }
}
