import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 108: the Worktrees section and the refresh. It uses a temp `LOAM_HOME`,
/// a temp git repo with a temp bare repo as `origin`, the core's fake `claude` in hook mode, and the
/// core's fake `gh`. It never touches `~/.loam`, a real repo, or GitHub.
/// `LOAM_DRIVER_FAKE_CLAUDE` and `LOAM_DRIVER_FAKE_GH` name the fake binaries.
@MainActor
extension Scenarios {
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    /// A worktree of the scenario: its ID, branch, and folder.
    private typealias Made = (id: String, branch: String, path: String)

    static func worktreesSection(_ app: DriverApp) async throws {
        do { try await worktreesSectionSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// The GitHub that the fake `gh` answers from, for the repo `example/widgets`: PR 16 of the branch
    /// `native-panel` has 2 failed checks of 3 and is `behind` commits behind main. PR 22 of the branch
    /// `link-labels` passes its one check, and `approved` says whether a review approves it.
    private static func ghState(behind: Int, approved: Bool) throws -> Data {
        func pull(_ number: Int, _ branch: String, title: String, mergeState: String, review: String) -> [String: Any] {
            ["number": number, "title": title, "url": "https://github.com/example/widgets/pull/\(number)",
             "state": "OPEN", "mergeable": "MERGEABLE", "mergeStateStatus": mergeState, "reviewDecision": review,
             "baseRefName": "main", "headRefName": branch, "headRefOid": String(repeating: "a", count: 40),
             "commits": ["totalCount": 2]]
        }
        func check(_ name: String, _ conclusion: String) -> [String: Any] {
            ["__typename": "CheckRun", "name": name, "status": "COMPLETED", "conclusion": conclusion, "isRequired": true,
             "startedAt": "2026-01-01T10:00:00Z", "completedAt": "2026-01-01T10:01:00Z",
             "detailsUrl": "https://github.com/example/widgets/actions/runs/1/job/1",
             "checkSuite": ["workflowRun": ["workflow": ["name": name]]]]
        }
        func detail(state: String, checks: [[String: Any]], behind: Int, reviews: [[String: Any]]) -> [String: Any] {
            ["baseRef": ["compare": ["behindBy": behind]],
             "commits": ["nodes": [["commit": ["statusCheckRollup": [
                "state": state, "contexts": ["totalCount": checks.count, "nodes": checks]]]]]],
             "latestOpinionatedReviews": ["nodes": reviews], "reviewThreads": ["nodes": [Any]()]]
        }
        let state: [String: Any] = [
            "refs": ["link-labels", "native-panel"],
            "pulls": [
                pull(16, "native-panel", title: "Native panel", mergeState: "BLOCKED", review: "REVIEW_REQUIRED"),
                pull(22, "link-labels", title: "Link labels", mergeState: approved ? "CLEAN" : "BLOCKED",
                     review: approved ? "APPROVED" : "REVIEW_REQUIRED"),
            ],
            "details": [
                "16": detail(state: "FAILURE", checks: [check("build", "SUCCESS"), check("lint", "FAILURE"), check("test", "FAILURE")],
                             behind: behind, reviews: []),
                "22": detail(state: "SUCCESS", checks: [check("build", "SUCCESS")], behind: 0,
                             reviews: approved ? [["state": "APPROVED"]] : []),
            ],
        ]
        return try JSONSerialization.data(withJSONObject: state)
    }

    private static func worktreesSectionSteps(_ app: DriverApp) async throws {
        let rig = try PanelRig(outFolder: app.outFolder)
        let environment = ProcessInfo.processInfo.environment
        guard let fakeClaude = environment["LOAM_DRIVER_FAKE_CLAUDE"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_CLAUDE does not name the fake claude")
        }
        guard let fakeGH = environment["LOAM_DRIVER_FAKE_GH"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_GH does not name the fake gh")
        }
        let fm = FileManager.default
        func script(_ text: String, at url: URL) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        // The session panes find a fake `claude`.
        let bin = rig.root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.copyItem(atPath: fakeClaude, toPath: bin.appendingPathComponent("claude").path)
        let invocationFile = rig.root.appendingPathComponent("claude-invocation.json")

        // The `gh` that the core runs (LOAM_GH): the fake, with a mode file to make it fail, and a
        // second path to hide it ("not installed").
        let ghWrapper = rig.root.appendingPathComponent("gh-for-loam")
        let ghHidden = rig.root.appendingPathComponent("gh-for-loam.hidden")
        let ghStateFile = rig.root.appendingPathComponent("gh-state.json")
        let ghLog = rig.root.appendingPathComponent("gh-calls.jsonl")
        let ghMode = rig.root.appendingPathComponent("gh-mode")
        try script("#!/bin/sh\nmode=$(cat '\(ghMode.path)' 2>/dev/null)\n[ -n \"$mode\" ] && export LOAM_FAKE_GH_FAIL=\"$mode\"\n"
                   + "exec '\(fakeGH)' \"$@\"\n", at: ghWrapper)
        try ghState(behind: 3, approved: true).write(to: ghStateFile)
        /// The refreshes so far: each one makes one first query for the repo, and only that query names `q0`.
        func refreshes() -> Int {
            ((try? String(contentsOf: ghLog, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("\"q0\"") }.count
        }

        // A repo with a pushed commit and three worktrees: two with a PR, and one with local work. The
        // remote becomes a GitHub address after the worktrees exist, so no git command asks the network.
        let origin = rig.root.appendingPathComponent("origin.git")
        let repo = rig.root.appendingPathComponent("widgets")
        try fm.createDirectory(at: origin, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(origin, ["init", "--bare", "-q"])
        try git(repo, ["init", "-q"])
        try "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-q", "-m", "first"])
        try git(repo, ["remote", "add", "origin", origin.path])
        try git(repo, ["push", "-q", "origin", "main"])
        try git(repo, ["fetch", "-q", "origin"])
        try git(repo, ["remote", "set-head", "origin", "main"])
        let plot = try rig.newPlot("Ship plot")
        try rig.loam(["repo", "add", plot, repo.path])
        let repoID = (try rig.show(plot)["repos"] as? [[String: Any]])?.first?["id"] as? String ?? ""
        try check(!repoID.isEmpty, "the plot has no repo")
        for branch in ["link-labels", "native-panel", "local-work"] { try rig.loam(["worktree", "new", plot, repoID, branch]) }
        try git(repo, ["remote", "set-url", "origin", "https://github.com/example/widgets.git"])
        func worktrees() throws -> [Made] {
            let text = try rig.loam(["worktree", "list", plot, "--json"])
            let list = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] ?? []
            return list.compactMap { entry in
                guard let worktree = entry["worktree"] as? [String: Any], let id = worktree["id"] as? String,
                      let branch = worktree["branch"] as? String, let path = worktree["path"] as? String else { return nil }
                return (id, branch, path)
            }
        }
        let made = try worktrees()
        try check(made.map(\.branch) == ["link-labels", "native-panel", "local-work"], "the core lists \(made.map(\.branch))")
        let (labels, panel, local) = (made[0], made[1], made[2])
        try "unsaved\n".write(to: URL(fileURLWithPath: local.path).appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let client = LoamClient(binary: rig.binary, environment: rig.environment.merging(try rig.neutralPrompt()) { $1 }.merging([
            "PATH": bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin"),
            "LOAM_FAKE_CLAUDE_OUT": invocationFile.path, "LOAM_FAKE_CLAUDE_HOOKS": "1", "LOAM_FAKE_CLAUDE_TURN": "1s",
            "LOAM_GH": ghWrapper.path, "LOAM_FAKE_GH_STATE": ghStateFile.path, "LOAM_FAKE_GH_LOG": ghLog.path,
        ]) { $1 })
        // The timers are far away, so only the triggers of this scenario make a refresh.
        let host = try await app.launchApp(client: client, state: rig.stateFile, terminals: true) { host in
            host.model.shipRefresh.timing.activeInterval = .seconds(3600)
            host.model.shipRefresh.timing.otherInterval = .seconds(3600)
        }
        let model = host.model
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }
        try await app.openPanel(host)

        func row(_ worktree: Made) -> String { "panel-worktree-\(worktree.id)" }
        func line(_ worktree: Made) -> String { app.text(of: row(worktree)) ?? "" }
        func refresh(_ worktree: Made) throws { try app.perform("Refresh", on: row(worktree)) }

        // 1. Launch refreshes the active plot. The rows come in the order of the core, with the status
        // line of each stage and no age.
        try await app.waitUntil("the first refresh") { refreshes() == 1 }
        try await app.waitUntil("the rows") { [labels, panel, local].allSatisfy { app.exists(row($0)) } }
        try await app.waitUntil("the stage lines") { line(labels).contains("Approved") && line(panel).contains("failed") }
        try check(line(labels) == "link-labels #22, 1 of 1 check passed \u{00B7} Approved", "link-labels reads \(line(labels))")
        try check(line(panel) == "native-panel #16, 2 of 3 checks failed \u{00B7} 3 behind main", "native-panel reads \(line(panel))")
        try check(line(local) == "local-work, 1 changed", "local-work reads \(line(local))")
        let tops = try [labels, panel, local].map { worktree in
            try AccessibilityProbe.shared.node(row(worktree))?.frame?.minY ?? { throw DriverFailure("no frame for \(worktree.branch)") }()
        }
        try check(tops == tops.sorted() && Set(tops).count == 3, "the rows are not in the order of the core: \(tops)")
        try check(app.exists("panel-add-worktree"), "no + for a new worktree")
        try check(!app.exists("panel-worktrees-age"), "fresh data shows an age")
        try check(["ghMissing", "ghSignedOut", "noAccess"].allSatisfy { !app.exists("panel-ship-notice-\($0)") }, "a notice shows with gh working")
        app.screenshot("ship-section")

        // 2. A refresh from the row menu takes the new state from its own output, and writes no change
        // marker (the change feed would not know it).
        let marker = rig.loamHome.appendingPathComponent("loam.changed")
        let markerBefore = try Data(contentsOf: marker)
        try ghState(behind: 4, approved: true).write(to: ghStateFile)
        try refresh(panel)
        try await app.waitUntil("4 behind main") { line(panel).contains("4 behind main") }
        try check(refreshes() == 2, "\(refreshes()) refreshes, not 2")
        try check((try? Data(contentsOf: marker)) == markerBefore, "a refresh rewrote loam.changed")

        // 3. `gh` is not installed: a neutral callout with the command. Dismiss hides it, and it stays
        // hidden at the next refresh.
        try fm.moveItem(at: ghWrapper, to: ghHidden)
        try refresh(panel)
        try await app.waitUntil("the gh missing callout") { app.exists("panel-ship-notice-ghMissing") }
        try check(app.text(of: "panel-ship-notice-ghMissing")?.contains("brew install gh") == true,
                  "the callout reads \(app.text(of: "panel-ship-notice-ghMissing") ?? "nothing")")
        try check(!app.exists("panel-ship-sign-in"), "the missing callout has Sign in")
        app.screenshot("ship-gh-missing")
        try app.click("panel-ship-dismiss-ghMissing")
        try await app.waitUntil("Dismiss hides the callout") { !app.exists("panel-ship-notice-ghMissing") }
        try refresh(panel)
        await app.sleep(1.5)
        try check(!app.exists("panel-ship-notice-ghMissing"), "the callout came back at the next refresh")
        try fm.moveItem(at: ghHidden, to: ghWrapper)

        // 4. `gh` is signed out: the callout has Sign in. It opens a shell in the plot with the command
        // typed and not sent. The plot refreshes when that pane closes.
        try "signed_out".write(to: ghMode, atomically: true, encoding: .utf8)
        try refresh(panel)
        try await app.waitUntil("the signed out callout") { app.exists("panel-ship-notice-ghSignedOut") }
        try check(app.exists("panel-ship-sign-in") && app.exists("panel-ship-dismiss-ghSignedOut"), "the callout lacks its buttons")
        app.screenshot("ship-signed-out")
        let panesBefore = Set(model.workspace.allPaneIDs)
        try app.click("panel-ship-sign-in")
        try await app.waitUntil("a shell pane") { model.workspace.allPaneIDs.contains { !panesBefore.contains($0) } }
        let shell = try model.workspace.allPaneIDs.first { !panesBefore.contains($0) } ?? { throw DriverFailure("no new pane") }()
        try check(model.workspace.spec(of: shell)?.kind == .shell && model.workspace.spec(of: shell)?.space == .plot(plot),
                  "the pane is not a shell in the plot")
        guard let terminal = host.paneView(shell) as? TerminalSurfaceView else { throw DriverFailure("the shell has no terminal") }
        try await app.waitUntil("the command is typed") { terminal.screenText().contains("gh auth login") }
        await app.sleep(1.0)
        // The command stands once, at the last prompt, with nothing after it: the app did not press
        // Return, which would run it and show output or a new prompt. The text went in after the shell
        // started, so the terminal did not echo it a second time.
        try check(app.lines(terminal).last { !$0.isEmpty }?.hasSuffix("gh auth login") == true,
                  "the last line is not the typed command: \(app.lines(terminal).suffix(4))")
        try check(terminal.allText().components(separatedBy: "gh auth login").count == 2, "the command shows more than once")
        // Text with a line break inside it is refused: a shell would read the break as Return. Nothing
        // is typed, and the terminal still holds the one command.
        do {
            _ = try terminal.pasteWithoutReturn("echo one\necho two")
            throw DriverFailure("the terminal took text with a line break inside it")
        } catch PaneTextError.lineBreakInside {}
        await app.sleep(0.5)
        try check(!terminal.allText().contains("echo one"), "the refused text shows in the terminal")
        app.screenshot("ship-sign-in-pane")
        let before = refreshes()
        try "".write(to: ghMode, atomically: true, encoding: .utf8)
        model.closePane(shell)
        try await app.waitUntil("the refresh after the pane closed") { refreshes() == before + 1 }
        try await app.waitUntil("the callout goes") { !app.exists("panel-ship-notice-ghSignedOut") }

        // 5. A Stop of a session in the plot makes one refresh, 5 s after the first Stop. The second
        // Stop comes within that time and joins it. The new state shows in the row.
        try ghState(behind: 4, approved: false).write(to: ghStateFile)
        model.openPlotSession(plot)
        let session = try model.workspace.selectedTab(of: .plot(plot))?.focused ?? { throw DriverFailure("no session pane") }()
        try await app.waitUntil("the session started") { model.workspace.session(of: session)?.started == true }
        try await app.waitUntil("the terminal has the keys") { app.window.firstResponder is TerminalSurfaceView }
        let beforeStops = refreshes()
        var firstStop = Date()
        for turn in 1...2 {
            try app.type("go")
            app.press(.returnKey)
            try await app.waitUntil("turn \(turn) starts") { model.workspace.session(of: session)?.state == .working }
            try await app.waitUntil("turn \(turn) ends") { model.workspace.session(of: session)?.state == .idle }
            if turn == 1 { firstStop = Date() }
        }
        try check(Date().timeIntervalSince(firstStop) < model.shipRefresh.timing.stopWindow.seconds, "the second Stop came after the window")
        try check(refreshes() == beforeStops, "a refresh ran before the window ended")
        try await app.waitUntil("one refresh after the Stops", timeout: 10) { refreshes() == beforeStops + 1 }
        try await app.waitUntil("review required") { line(labels) == "link-labels #22, Review required" }
        await app.sleep(1.5)
        try check(refreshes() == beforeStops + 1, "\(refreshes() - beforeStops) refreshes for two Stops")
        app.screenshot("ship-after-stop")

        // 6. Opening a plot refreshes it. A trip through Home and back is an open.
        let beforeOpen = refreshes()
        model.activateHome()
        model.activate(plot: plot)
        try await app.waitUntil("a refresh at the open") { refreshes() == beforeOpen + 1 }
        // Home hides the panel, and the plot brings it back.
        try await app.waitUntil("the panel is back") { app.exists(row(local)) }

        // 6b. A refresh never moves the keyboard. Each one writes a new `pr_checked_at`, so the rows change and
        // the window renders. You type in the Where it stands field of the panel: the field keeps the focus,
        // and the next keys go into it, not into the session.
        await app.sleep(1.5)  // The refresh of the open is done, and the next one has a later time.
        try app.fill("panel-whereItStands", with: "draft")
        try check(AccessibilityProbe.shared.isFocused("panel-whereItStands"), "the field has no focus")
        let rowsBefore = model.worktrees[plot]
        try refresh(panel)
        try await app.waitUntil("the refresh changes the rows") { model.worktrees[plot] != rowsBefore }
        await app.sleep(0.5)
        try check(AccessibilityProbe.shared.isFocused("panel-whereItStands"), "a refresh took the focus from the field")
        try check(!(app.window.firstResponder is TerminalSurfaceView), "a refresh gave the keys to the terminal")
        try app.type("more")
        try await app.waitUntil("the keys went into the field") { app.text(of: "panel-whereItStands") == "draftmore" }
        try app.click("panel-revert-whereItStands")
        try await app.waitUntil("Revert drops the draft") { !app.exists("panel-revert-whereItStands") }

        // 7. A folder that is gone shows "Folder is gone" and no PR data.
        try fm.removeItem(atPath: local.path)
        try refresh(local)
        try await app.waitUntil("the gone row") { line(local) == "local-work, Folder is gone" }

        // 8. Offline keeps the rows and shows their age once they are over 5 min old.
        let database = rig.loamHome.appendingPathComponent("loam.db")
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [database.path, ".timeout 5000", "UPDATE pr_cache SET checked_at = checked_at - 600000 WHERE checked_at > 0;"]
        try sqlite.run()
        sqlite.waitUntilExit()
        try check(sqlite.terminationStatus == 0, "sqlite3 exited \(sqlite.terminationStatus)")
        try "offline".write(to: ghMode, atomically: true, encoding: .utf8)
        try refresh(panel)
        try await app.waitUntil("the age") { app.text(of: "panel-worktrees-age")?.hasPrefix("Updated ") == true }
        try check(line(labels) == "link-labels #22, Review required", "offline changed the rows: \(line(labels))")
        app.screenshot("ship-offline-age")
        try "".write(to: ghMode, atomically: true, encoding: .utf8)
        try refresh(panel)
        try await app.waitUntil("fresh data has no age") { !app.exists("panel-worktrees-age") }
    }
}

private extension Duration {
    /// The length in seconds.
    var seconds: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
