import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 112: the Land sheet. It uses a temp `LOAM_HOME`, a temp git repo with a made-up GitHub
/// address, and the core's fake `gh` (`LOAM_DRIVER_FAKE_GH`) with the repo `example/widgets`. A land is real: `loam
/// worktree land` merges the PR in the fake `gh`, deletes the branch there, closes nothing itself, and removes the
/// worktree. The app calls `gh` through `loam` only, so the fake `gh` log shows each merge. It never touches `~/.loam`, a
/// real repo, or GitHub.
@MainActor
extension Scenarios {
    private static func expectLand(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func landSheet(_ app: DriverApp) async throws {
        do { try await landSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// What GitHub says about the PRs of `example/widgets`. All five stand on the commit `head`.
    ///
    /// - 22 `link-labels`: three checks passed, approved. It is ready to merge.
    /// - 24 `fix-login`: one check passed, approved. It is ready to merge.
    /// - 25 `rename-users`: one check passed, approved. It is ready to merge.
    /// - 16 `native-panel`: two checks failed.
    /// - 23 `unit-tests`: a check still runs, approved.
    ///
    /// With `refusal`, GitHub refuses each merge with that message. With `newHead`, PR 25 stands on that commit.
    private static func landGitHub(head: String, newHead: String? = nil, refusal: String? = nil) throws -> Data {
        func pull(_ number: Int, _ branch: String, title: String, mergeState: String, head: String = head) -> [String: Any] {
            ["number": number, "title": title, "url": "https://github.com/example/widgets/pull/\(number)",
             "state": "OPEN", "mergeable": "MERGEABLE", "mergeStateStatus": mergeState, "reviewDecision": "APPROVED",
             "baseRefName": "main", "headRefName": branch, "headRefOid": head, "commits": ["totalCount": 9]]
        }
        func check(_ name: String, _ conclusion: String?, run: Int) -> [String: Any] {
            var node: [String: Any] = [
                "__typename": "CheckRun", "name": name, "status": conclusion == nil ? "IN_PROGRESS" : "COMPLETED",
                "conclusion": conclusion ?? NSNull(), "isRequired": true, "startedAt": "2026-01-01T10:00:00Z",
                "detailsUrl": "https://github.com/example/widgets/actions/runs/\(run)/job/1",
                "checkSuite": ["workflowRun": ["databaseId": run, "workflow": ["name": name]]],
            ]
            if conclusion != nil { node["completedAt"] = "2026-01-01T10:03:10Z" }
            return node
        }
        func detail(_ state: String, _ checks: [[String: Any]]) -> [String: Any] {
            ["baseRef": ["compare": ["behindBy": 0]],
             "commits": ["nodes": [["commit": ["statusCheckRollup": [
                "state": state, "contexts": ["totalCount": checks.count, "nodes": checks]]]]]],
             "latestOpinionatedReviews": ["nodes": [["state": "APPROVED"]]], "reviewThreads": ["nodes": [Any]()]]
        }
        var state: [String: Any] = [
            "refs": ["link-labels", "fix-login", "rename-users", "native-panel", "unit-tests"],
            "repository": ["mergeCommitAllowed": false, "squashMergeAllowed": true, "rebaseMergeAllowed": true,
                           "viewerDefaultMergeMethod": "SQUASH"],
            "pulls": [
                pull(22, "link-labels", title: "Link labels", mergeState: "CLEAN"),
                pull(24, "fix-login", title: "Fix login", mergeState: "CLEAN"),
                pull(25, "rename-users", title: "Rename users", mergeState: "CLEAN", head: newHead ?? head),
                pull(16, "native-panel", title: "Native panel", mergeState: "BLOCKED"),
                pull(23, "unit-tests", title: "Unit tests", mergeState: "BLOCKED"),
            ],
            "details": [
                "22": detail("SUCCESS", [check("build", "SUCCESS", run: 401), check("lint", "SUCCESS", run: 402), check("test", "SUCCESS", run: 403)]),
                "24": detail("SUCCESS", [check("build", "SUCCESS", run: 404)]),
                "25": detail("SUCCESS", [check("build", "SUCCESS", run: 410)]),
                "16": detail("FAILURE", [check("build", "SUCCESS", run: 405), check("lint", "FAILURE", run: 406), check("test", "FAILURE", run: 407)]),
                "23": detail("PENDING", [check("build", "SUCCESS", run: 408), check("test", nil, run: 409)]),
            ],
        ]
        if let refusal { state["merge_refusal"] = refusal }
        return try JSONSerialization.data(withJSONObject: state)
    }

    /// The commit at the head of a folder.
    private static func headCommit(of folder: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": folder, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let head = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, head.count == 40 else { throw DriverFailure("git rev-parse HEAD failed in \(folder)") }
        return head
    }

    private static func landSteps(_ app: DriverApp) async throws {
        guard let fakeGH = ProcessInfo.processInfo.environment["LOAM_DRIVER_FAKE_GH"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_GH does not name the fake gh")
        }
        let rig = try PanelRig(outFolder: app.outFolder)
        let ghState = rig.root.appendingPathComponent("gh-state.json")
        let ghLog = rig.root.appendingPathComponent("gh-calls.jsonl")

        // The calls that reached the fake `gh`, as words.
        func calls() -> [[String]] {
            ((try? String(contentsOf: ghLog, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["args"] as? [String]
            }
        }
        func merges(of number: Int) -> [[String]] { calls().filter { Array($0.prefix(3)) == ["pr", "merge", "\(number)"] } }
        /// The text of a row or a button: its label, else its value.
        func label(_ id: String) -> String {
            guard let node = AccessibilityProbe.shared.node(id) else { return "" }
            return [node.description, node.title, node.value].first { !$0.isEmpty } ?? ""
        }
        func value(_ id: String) -> String { AccessibilityProbe.shared.node(id)?.value ?? "" }
        /// The shot waits for the sheet to drop in and for the toast to fade in.
        func settledShot(_ name: String) async throws {
            try await Task.sleep(for: .seconds(LoamTheme.durationSlow * 2))
            app.screenshot(name)
        }

        // 1. A repo with five worktrees. native-panel has 2 files that are not committed. The remote becomes a GitHub
        // address after the worktrees exist, so no git command asks the network.
        let plot = try rig.newPlot("Widgets plot")
        let widgets = try makeRepo(rig, named: "widgets")
        try rig.loam(["repo", "add", plot, widgets.path])
        let labels = try makeWorktree(rig, plot: plot, repo: widgets, name: "link-labels")
        let fix = try makeWorktree(rig, plot: plot, repo: widgets, name: "fix-login")
        let rename = try makeWorktree(rig, plot: plot, repo: widgets, name: "rename-users")
        let panel = try makeWorktree(rig, plot: plot, repo: widgets, name: "native-panel")
        let units = try makeWorktree(rig, plot: plot, repo: widgets, name: "unit-tests")
        for name in ["notes.txt", "todo.txt"] {
            try "draft\n".write(to: URL(fileURLWithPath: panel.path).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try git(widgets, ["remote", "set-url", "origin", "https://github.com/example/widgets.git"])
        let head = try headCommit(of: labels.path)
        try landGitHub(head: head).write(to: ghState)
        try rig.loam(["set", plot, "where-it-stands", "Building the link labels."])

        let client = LoamClient(binary: rig.binary, environment: rig.environment.merging(try rig.neutralPrompt()) { $1 }.merging([
            "LOAM_GH": fakeGH, "LOAM_FAKE_GH_STATE": ghState.path, "LOAM_FAKE_GH_LOG": ghLog.path,
        ]) { $1 })
        // The timers are far away, so only the launch and the opens of a popover or a sheet ask GitHub.
        let host = try await app.launchApp(client: client, state: rig.stateFile, terminals: true) { host in
            host.model.shipRefresh.timing.activeInterval = .seconds(3600)
            host.model.shipRefresh.timing.otherInterval = .seconds(3600)
        }
        // Room in the action bar for the toast after the pane label.
        host.window.setFrame(NSRect(x: 80, y: 80, width: 1360, height: 760), display: true)
        let model = host.model
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }
        try await app.waitUntil("the stages") {
            model.worktreeStatus(labels.id)?.stage == .readyToMerge && model.worktreeStatus(fix.id)?.stage == .readyToMerge
                && model.worktreeStatus(rename.id)?.stage == .readyToMerge
                && model.worktreeStatus(panel.id)?.stage == .checksFailed && model.worktreeStatus(units.id)?.stage == .checksRunning
        }
        func worktree(_ made: (id: String, path: String)) throws -> Worktree {
            try model.worktreeStatus(made.id)?.worktree ?? { throw DriverFailure("the list has no worktree \(made.id)") }()
        }
        func sheetIsUp(_ number: Int) -> Bool {
            app.exists("land-sheet-merge") && model.landContent?.number == number
        }
        func sheetCloses() async throws {
            try await app.waitUntil("the sheet closes", timeout: 30) { !model.landSheet.isOpen && !app.exists("land-sheet") }
        }

        // 2. A worktree that GitHub does not let merge: native-panel has 2 failed checks and 2 files that are not committed.
        // Merge stays off, whatever you press. Return and Command-Return do nothing, and the call to GitHub never happens.
        try expectLand(model.openLandSheet(panel.id), "the sheet did not open for native-panel")
        try await app.waitUntil("the sheet shows the plan of native-panel") { sheetIsUp(16) }
        try expectLand(label("land-sheet-title") == "Land #16 Native panel", "the title reads \(label("land-sheet-title"))")
        for id in ["checks", "worktree"] {
            try expectLand(label("land-sheet-row-\(id)").hasSuffix("blocks the merge"), "the \(id) row does not block: \(label("land-sheet-row-\(id)"))")
        }
        try expectLand(label("land-sheet-row-worktree").contains("2 changed"), "the worktree row reads \(label("land-sheet-row-worktree"))")
        try expectLand(label("land-sheet-footer") == "Fix the 2 items in rust before you merge.", "the footer reads \(label("land-sheet-footer"))")
        try expectLand(!AccessibilityProbe.shared.isEnabled("land-sheet-merge"), "Merge is on while two checks block")
        try expectLand(label("land-sheet-merge") == "Merge #16", "the button reads \(label("land-sheet-merge"))")
        app.press(.returnKey)
        app.press(.returnKey, flags: .command)
        _ = AccessibilityProbe.shared.press("land-sheet-merge")
        await app.sleep(1)
        try expectLand(model.landSheet.isOpen && !model.landSheet.isMerging && merges(of: 16).isEmpty,
                       "a key or a press merged a blocked worktree: \(calls().map { $0.joined(separator: " ") })")
        try await settledShot("land-sheet-blocked")
        app.press(.escape)
        try await sheetCloses()

        // 3. A check still runs: the button waits for GitHub with --auto, the third box is off, and nothing closes or saves.
        let beforeAuto = try rig.lastChangeID(plot)
        try expectLand(model.openLandSheet(units.id), "the sheet did not open for unit-tests")
        try await app.waitUntil("the sheet shows the plan of unit-tests") { sheetIsUp(23) }
        try expectLand(label("land-sheet-merge") == "Merge when ready" && AccessibilityProbe.shared.isEnabled("land-sheet-merge"),
                       "the button reads \(label("land-sheet-merge"))")
        try expectLand(label("land-sheet-footer") == "GitHub merges #23 when its checks pass. Loam tidies up after the merge.",
                       "the footer reads \(label("land-sheet-footer"))")
        try expectLand(!AccessibilityProbe.shared.isEnabled("land-sheet-move-on") && !app.exists("land-sheet-where"),
                       "the third box is on for a merge that waits")
        try await settledShot("land-sheet-running")
        try app.click("land-sheet-merge")
        try await sheetCloses()
        try await app.waitUntil("the toast of the merge that waits") { app.text(of: "action-bar-toast")?.contains("#23 will merge when its checks pass.") == true }
        try expectLand(merges(of: 23).count == 1 && merges(of: 23)[0].contains("--auto"), "gh got \(merges(of: 23))")
        try expectLand(FileManager.default.fileExists(atPath: units.path), "the worktree of a merge that waits is gone")
        try expectLand(try rig.lastChangeID(plot) == beforeAuto, "a merge that waits wrote a change")

        // 4. Land fix-login from the pill on its row, and keep the worktree. The row stays, faded, with Remove...
        try await app.openPanel(host)
        try await app.waitUntil("the pill of the ready rows") {
            app.exists("panel-worktree-land-\(fix.id)") && app.exists("panel-worktree-land-\(labels.id)")
        }
        try expectLand(!app.exists("panel-worktree-land-\(panel.id)") && !app.exists("panel-worktree-land-\(units.id)"),
                       "a row that is not ready has the Land pill")
        try await settledShot("land-pill")
        try app.click("panel-worktree-land-\(fix.id)")
        try await app.waitUntil("the sheet shows the plan of fix-login") { sheetIsUp(24) }
        try app.click("land-sheet-remove")
        try await app.waitUntil("the first box is off") { value("land-sheet-remove") == "0" }
        try app.click("land-sheet-move-on")
        try await app.waitUntil("the third box is off, with no box under it") { value("land-sheet-move-on") == "0" && !app.exists("land-sheet-where") }
        let beforeKept = try rig.lastChangeID(plot)
        try app.click("land-sheet-merge")
        try await sheetCloses()
        try await app.waitUntil("the toast of the merge") { app.text(of: "action-bar-toast")?.contains("Merged #24.") == true }
        let keep = merges(of: 24)
        try expectLand(keep.count == 1 && keep[0].contains("--squash"), "gh got \(keep)")
        try expectLand(FileManager.default.fileExists(atPath: fix.path), "the kept worktree is gone")
        try expectLand(try rig.lastChangeID(plot) == beforeKept, "a merge with the third box off wrote a change")
        try await app.waitUntil("the row is merged, with Remove") {
            model.worktreeStatus(fix.id)?.stage == .merged && app.exists("panel-worktree-remove-\(fix.id)")
                && !app.exists("panel-worktree-land-\(fix.id)")
        }
        try await settledShot("land-kept-row")

        // 5. Land link-labels with a shell open in it, from the chip and the popover. Then close the panel.
        try app.pressMenuKey("i")
        try await app.waitUntil("the panel closes") { !app.exists("panel-whereItStands") }
        model.openWorktreePane(try worktree(labels), kind: .shell)
        let pane = try model.workspace.focusedPane ?? { throw DriverFailure("no focused pane") }()
        try await app.waitUntil("the shell has the keys") {
            model.focusedWorktree?.id == labels.id && host.window.firstResponder === host.paneView(pane)
        }
        try await app.waitUntil("the chip") { app.exists("action-bar-pr-chip") }
        try app.click("action-bar-pr-chip")
        try await app.waitUntil("the popover opens") { app.exists("pr-popover") && model.prPopover.worktreeID == labels.id }
        try await app.waitUntil("the popover is done") { !model.prPopover.isRefreshing }
        try expectLand(label("pr-popover-primary") == "Land\u{2026}", "the popover button reads \(label("pr-popover-primary"))")
        try app.click("pr-popover-primary")
        try await app.waitUntil("the sheet shows the plan of link-labels") { sheetIsUp(22) && !app.exists("pr-popover") }
        try expectLand(label("land-sheet-title") == "Land #22 Link labels", "the title reads \(label("land-sheet-title"))")
        for id in ["checks", "review", "behind_base", "conflicts", "worktree"] {
            try expectLand(app.exists("land-sheet-row-\(id)") && !label("land-sheet-row-\(id)").hasSuffix("blocks the merge"),
                           "the \(id) row blocks or is missing")
        }
        try expectLand(label("land-sheet-row-checks").contains("3 of 3"), "the checks row reads \(label("land-sheet-row-checks"))")
        try expectLand(label("land-sheet-footer") == "You cannot undo a merge.", "the footer reads \(label("land-sheet-footer"))")
        try expectLand(label("land-sheet-merge") == "Merge #22" && AccessibilityProbe.shared.isEnabled("land-sheet-merge"),
                       "the button reads \(label("land-sheet-merge"))")
        try expectLand(app.exists("land-sheet-method"), "the sheet has no merge method")
        try expectLand(label("land-sheet-remove").contains("Close its pane and remove the worktree"), "the first box reads \(label("land-sheet-remove"))")
        for id in ["land-sheet-remove", "land-sheet-delete-branch", "land-sheet-move-on"] {
            try expectLand(value(id) == "1", "the box \(id) is off")
        }
        let sentence = "Merged #22 Link labels."
        let prefill = app.text(of: "land-sheet-where") ?? ""
        try expectLand(prefill.hasPrefix(sentence) && prefill.contains("Building the link labels."), "the Where it stands box reads \(prefill)")
        try expectLand(!(host.window.firstResponder is TerminalSurfaceView), "the terminal kept the keys")
        try await settledShot("land-sheet-ready")

        // The box selects the sentence about the merge when it takes the keys, so one key replaces it.
        try expectLand(AccessibilityProbe.shared.focus("land-sheet-where"), "the box took no focus")
        try await app.waitUntil("the box has the keys") { host.window.firstResponder is NSTextView }
        try await app.waitUntil("the sentence is selected") {
            (host.window.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 0, length: sentence.count)
        }
        try app.type("Shipped link labels.")
        try await app.waitUntil("the sentence is replaced") { app.text(of: "land-sheet-where")?.hasPrefix("Shipped link labels. Building") == true }
        let wanted = (app.text(of: "land-sheet-where") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // GitHub refuses the merge. With the first box off, no pane closes. The sheet stays open with the message of GitHub.
        let refusal = "Pull request is not mergeable: required reviews are missing"
        try landGitHub(head: head, refusal: refusal).write(to: ghState)
        try app.click("land-sheet-remove")
        try await app.waitUntil("the first box is off") { value("land-sheet-remove") == "0" }
        try app.click("land-sheet-merge")
        try await app.waitUntil("the message of GitHub") { app.text(of: "land-sheet-error")?.contains(refusal) == true }
        try expectLand(model.landSheet.isOpen && !model.landSheet.isMerging && app.exists("land-sheet-merge"), "the sheet closed or still merges")
        try expectLand(AccessibilityProbe.shared.isEnabled("land-sheet-merge"), "Merge is off after a refusal")
        try expectLand(merges(of: 22).count == 1, "gh got \(merges(of: 22))")
        try expectLand(FileManager.default.fileExists(atPath: labels.path) && model.landPanes(of: try worktree(labels)) == [pane],
                       "the refusal removed the worktree or closed the pane")
        try expectLand(try rig.lastChangeID(plot) == beforeKept, "a refused merge wrote a change")
        try await settledShot("land-sheet-refused")

        // GitHub takes the merge on the second try, with the first box on. The pane closes first, and then the worktree goes.
        try landGitHub(head: head).write(to: ghState)
        try app.click("land-sheet-remove")
        try await app.waitUntil("the first box is on") { value("land-sheet-remove") == "1" }
        let beforeLand = try rig.lastChangeID(plot)
        try app.click("land-sheet-merge")
        try await app.waitUntil("the pane closes", timeout: 30) { !model.workspace.allPaneIDs.contains(pane) }
        try await sheetCloses()
        try await app.waitUntil("the toast of the merge") { app.text(of: "action-bar-toast")?.contains("Merged #22. Removed the worktree link-labels.") == true }
        let both = merges(of: 22)
        try expectLand(both.count == 2 && both[1].contains("--squash"), "gh got \(both)")
        try expectLand(!FileManager.default.fileExists(atPath: labels.path), "the worktree folder is still there")
        let listed = try rig.loam(["worktree", "list", plot, "--json"])
        try expectLand(!listed.contains("link-labels") && listed.contains("fix-login"), "the list reads \(listed)")
        let github = try JSONSerialization.jsonObject(with: Data(contentsOf: ghState)) as? [String: Any] ?? [:]
        try expectLand(!(github["refs"] as? [String] ?? []).contains("link-labels"), "the branch is still on GitHub")
        try expectLand(model.worktreeStatus(labels.id) == nil, "the app still lists link-labels")

        // Where it stands has the text of the box, saved as one change by the app.
        let saved = (try rig.show(plot)["where_it_stands"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try expectLand(saved == wanted, "Where it stands reads \(saved), not \(wanted)")
        let added = try rig.changes(plot).filter { ($0["id"] as? Int ?? 0) > beforeLand }
        let actor = (added.first?["actor"] as? [String: Any])?["kind"] as? String
        try expectLand(added.count == 1 && actor == "app", "the land wrote \(added.count) changes, by \(actor ?? "nobody")")
        try await settledShot("land-toast")

        // The change has Undo in the log of the panel.
        try await app.openPanel(host)
        let changeID = added[0]["id"] as? Int ?? 0
        try await app.waitUntil("the change with Undo") { app.exists("change-undo-\(changeID)") }
        try expectLand(!app.exists("panel-worktree-\(labels.id)") && app.exists("panel-worktree-remove-\(fix.id)"), "the Worktrees section is wrong")
        try app.pressMenuKey("i")
        try await app.waitUntil("the panel closes again") { !app.exists("panel-whereItStands") }

        // 6. Return in the Where it stands box only adds a line. A held Return repeats, and it never reaches the merge.
        // rename-users is ready, so a merge here would show in the log of gh.
        try expectLand(model.openLandSheet(rename.id), "the sheet did not open for rename-users")
        try await app.waitUntil("the sheet shows the plan of rename-users") { sheetIsUp(25) }
        // The sheet asks for the keys for a short time after it opens. A box that takes them before that loses them again.
        await app.sleep(0.5)
        try expectLand(AccessibilityProbe.shared.focus("land-sheet-where"), "the box took no focus")
        try await app.waitUntil("the box has the keys") { host.window.firstResponder is NSTextView }
        // The window is not the key window of an active app in a driver run, so SwiftUI learns about the focus of the box
        // from the first key that the box takes.
        try app.type("x")
        await app.sleep(0.3)
        func noMerge(_ key: String) async throws {
            await app.sleep(0.6)
            try expectLand(model.landSheet.isOpen && !model.landSheet.isMerging && merges(of: 25).isEmpty,
                           "\(key) in the box merged: gh got \(merges(of: 25))")
        }
        app.press(.returnKey)
        try await noMerge("a Return")
        app.keyDown(.returnKey)
        try await noMerge("the first press of a held Return")
        for _ in 0..<3 {
            app.keyDown(.returnKey, isARepeat: true)
            try await noMerge("a repeat of a held Return")
        }
        app.keyUp(.returnKey)
        try await noMerge("the end of a held Return")
        app.press(.escape)
        try await sheetCloses()

        // With the keys on the sheet, Return merges a ready worktree. The PR gets a new commit after the sheet read it, so
        // the core stops the merge and the sheet shows the message. Merge is off until the new plan is back. The repeats of the
        // held key do nothing, and a new press takes the new commit.
        try expectLand(model.openLandSheet(rename.id), "the sheet did not open again for rename-users")
        try await app.waitUntil("the sheet shows the plan of rename-users again") { sheetIsUp(25) }
        await app.sleep(0.5)
        let newHead = String(repeating: "c", count: 40)
        try landGitHub(head: head, newHead: newHead).write(to: ghState)
        app.keyDown(.returnKey)
        try await app.waitUntil("the message about the new commit", timeout: 30) {
            app.text(of: "land-sheet-error")?.contains("has new commits since you looked at it") == true
        }
        try await app.waitUntil("the plan of the new commit") { model.landSheet.plan?.pr.headOID == newHead && sheetIsUp(25) }
        try expectLand(model.landSheet.isOpen && !model.landSheet.isMerging && AccessibilityProbe.shared.isEnabled("land-sheet-merge"),
                       "the sheet closed or stays locked after the new plan")
        try expectLand(merges(of: 25).isEmpty, "gh got \(merges(of: 25)) for a PR with a new commit")
        try expectLand(FileManager.default.fileExists(atPath: rename.path), "the stopped merge removed the worktree")
        try await settledShot("land-sheet-new-commits")

        // The key is still down while the core stops the merge. Its repeats do not start another one.
        for _ in 0..<3 { app.keyDown(.returnKey, isARepeat: true) }
        app.keyUp(.returnKey)
        await app.sleep(1)
        try expectLand(model.landSheet.isOpen && !model.landSheet.isMerging && merges(of: 25).isEmpty,
                       "the repeats of a held Return merged: gh got \(merges(of: 25))")

        app.press(.returnKey)
        try await sheetCloses()
        try await app.waitUntil("the toast of the merge by Return") {
            app.text(of: "action-bar-toast")?.contains("Merged #25. Removed the worktree rename-users.") == true
        }
        let last = merges(of: 25)
        try expectLand(last.count == 1 && last[0].contains("--match-head-commit") && last[0].last == newHead, "gh got \(last)")
        try expectLand(!FileManager.default.fileExists(atPath: rename.path), "the worktree of rename-users is still there")
    }
}
