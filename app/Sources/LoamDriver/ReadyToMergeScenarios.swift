import AppKit
import LoamKit

/// Driver scenario for ticket 107: the stage marks of the sidebar and the Ready to merge row. Two plots
/// each hold a repo whose `origin` names a made-up GitHub repo (example/widgets and example/gadgets),
/// and the core's fake `gh` answers for them (`LOAM_DRIVER_FAKE_GH`). `loam worktree list --refresh` fills
/// the PR cache, and the app reads that cache. Two worktrees are ready to merge, one in each plot.
/// ⌘⇧L selects the first, then the second, then the first again. It uses a temp `LOAM_HOME` and a fake
/// HOME, and never touches `~/.loam`, a real repo, or the real `gh`.
@MainActor
extension Scenarios {
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func readyToMerge(_ app: DriverApp) async throws {
        defer { NSApp.appearance = nil }
        do { try await readyToMergeSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// A worktree row that no repo row holds sits right under its plot. The app reads the repo rows from
    /// `loam export`, so a `loam` that fails that command leaves every worktree row under its plot. ⌘⇧L
    /// selects the ready one, and its row must show as selected, as a row under a repo row does.
    static func readyToMergeHomeless(_ app: DriverApp) async throws {
        do { try await readyToMergeHomelessSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private static func readyToMergeHomelessSteps(_ app: DriverApp) async throws {
        guard let fakeGH = ProcessInfo.processInfo.environment["LOAM_DRIVER_FAKE_GH"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_GH does not name the fake gh")
        }
        let rig = try PanelRig(outFolder: app.outFolder)
        let state = rig.root.appendingPathComponent("gh-state.json")
        let ghEnvironment = ["LOAM_GH": fakeGH, "LOAM_FAKE_GH_STATE": state.path]
        try ghState(ready: true).write(to: state, atomically: true, encoding: .utf8)

        let plot = try rig.newPlot("Alpha plot")
        let web = try makeRepo(rig, named: "web")
        try rig.loam(["repo", "add", plot, web.path])
        let fixLogin = try makeWorktree(rig, plot: plot, repo: web, name: "fix-login")
        let nativePanel = try makeWorktree(rig, plot: plot, repo: web, name: "native-panel")
        try git(web, ["remote", "set-url", "origin", "https://github.com/example/widgets.git"])
        try rig.loam(["worktree", "list", "--refresh"], extra: ghEnvironment)

        let noExport = rig.root.appendingPathComponent("loam-no-export")
        try "#!/bin/sh\nif [ \"$1\" = export ]; then exit 1; fi\nexec '\(rig.binary.path)' \"$@\"\n"
            .write(to: noExport, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: noExport.path)

        let host = try await app.launchApp(
            client: LoamClient(binary: noExport, environment: rig.environment.merging(ghEnvironment) { $1 }), state: rig.stateFile)
        let model = host.model
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }
        try await app.waitUntil("the app lists the 2 worktrees") { model.worktrees.values.joined().count == 2 }
        try await app.waitUntil("the Ready to merge row shows 1") { app.text(of: "attention-ready-to-merge") == "Ready to merge: 1" }
        let rows = model.sidebar.tree(of: plot).checkouts
        try expect(model.repoCheckouts.isEmpty && rows.count == 2 && rows.allSatisfy { $0.kind == .worktree },
                   "a repo row holds a worktree: \(rows.map(\.id))")

        try pressExactMenuKey("l", [.command, .shift])
        try await app.waitUntil("⌘⇧L selects the ready worktree") { model.sidebar.selection == .worktree(fixLogin.id) }
        try await app.waitUntil("the row shows as selected") { AccessibilityProbe.shared.isSelected("worktree-\(fixLogin.id)") }
        try expect(!AccessibilityProbe.shared.isSelected("worktree-\(nativePanel.id)"), "the other worktree row shows as selected")
        app.screenshot("homeless-worktree-selected")
    }

    /// A passing check run and one approval, for each open PR (the second query of the core).
    private static let passingChecks = #"""
        {"baseRef": {"compare": {"behindBy": 0}}, "latestOpinionatedReviews": {"nodes": [{"state": "APPROVED"}]},
         "reviewThreads": {"nodes": []},
         "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS", "contexts": {"totalCount": 1,
           "nodes": [{"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "isRequired": true, "conclusion": "SUCCESS"}]}}}}]}}
        """#

    /// What the fake `gh` knows. With `ready`, the PRs of fix-login and link-labels can merge. Without it,
    /// they wait for a review. native-panel always waits for a review.
    private static func ghState(ready: Bool) -> String {
        func pull(_ number: Int, _ repo: String, _ title: String, _ branch: String, ready: Bool) -> String {
            """
            {"number": \(number), "title": "\(title)", "url": "https://github.com/example/\(repo)/pull/\(number)", "state": "OPEN",
             "mergeable": "MERGEABLE", "mergeStateStatus": "\(ready ? "CLEAN" : "BLOCKED")",
             "reviewDecision": "\(ready ? "APPROVED" : "REVIEW_REQUIRED")", "baseRefName": "main", "headRefName": "\(branch)",
             "headRefOid": "1111111111111111111111111111111111111111", "commits": {"totalCount": 2}}
            """
        }
        return """
            {"refs": ["fix-login", "native-panel", "link-labels"],
             "pulls": [\(pull(31, "widgets", "Fix login", "fix-login", ready: ready)),
                       \(pull(32, "widgets", "Native panel", "native-panel", ready: false)),
                       \(pull(41, "gadgets", "Link labels", "link-labels", ready: ready))],
             "details": {"31": \(passingChecks), "32": \(passingChecks), "41": \(passingChecks)}}
            """
    }

    /// A repo with one pushed commit, so a worktree starts from origin/main.
    private static func makeRepo(_ rig: PanelRig, named name: String) throws -> URL {
        let fm = FileManager.default
        let origin = rig.root.appendingPathComponent("\(name)-origin.git")
        let repo = rig.root.appendingPathComponent(name)
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
        return repo
    }

    /// `loam worktree new` through the rig. Returns the ID and the folder.
    private static func makeWorktree(_ rig: PanelRig, plot: String, repo: URL, name: String) throws -> (id: String, path: String) {
        let made = try rig.json(["worktree", "new", plot, repo.path, name])["worktree"] as? [String: Any]
        guard let id = made?["id"] as? String, let path = made?["path"] as? String else {
            throw DriverFailure("worktree new \(name) printed no worktree")
        }
        return (id, path)
    }

    private static func readyToMergeSteps(_ app: DriverApp) async throws {
        guard let fakeGH = ProcessInfo.processInfo.environment["LOAM_DRIVER_FAKE_GH"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_GH does not name the fake gh")
        }
        let rig = try PanelRig(outFolder: app.outFolder)
        let state = rig.root.appendingPathComponent("gh-state.json")
        let ghEnvironment = [
            "LOAM_GH": fakeGH, "LOAM_FAKE_GH_STATE": state.path, "LOAM_FAKE_GH_LOG": rig.root.appendingPathComponent("gh-calls.jsonl").path,
        ]
        try ghState(ready: true).write(to: state, atomically: true, encoding: .utf8)

        // 1. Two plots with a repo each. Each worktree starts from the local origin. Then origin names a
        // made-up GitHub repo, so no command may fetch after this.
        let alpha = try rig.newPlot("Alpha plot")
        let beta = try rig.newPlot("Beta plot")
        let web = try makeRepo(rig, named: "web")
        let docs = try makeRepo(rig, named: "docs")
        try rig.loam(["repo", "add", alpha, web.path])
        try rig.loam(["repo", "add", beta, docs.path])
        let fixLogin = try makeWorktree(rig, plot: alpha, repo: web, name: "fix-login")
        let nativePanel = try makeWorktree(rig, plot: alpha, repo: web, name: "native-panel")
        let linkLabels = try makeWorktree(rig, plot: beta, repo: docs, name: "link-labels")
        let localWork = try makeWorktree(rig, plot: beta, repo: docs, name: "local-work")
        try "notes\n".write(to: URL(fileURLWithPath: localWork.path).appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try git(web, ["remote", "set-url", "origin", "https://github.com/example/widgets.git"])
        try git(docs, ["remote", "set-url", "origin", "https://github.com/example/gadgets.git"])

        // 2. The refresh fills the cache. The app reads the cache and makes no call to gh.
        try rig.loam(["worktree", "list", "--refresh"], extra: ghEnvironment)
        let listed = try JSONSerialization.jsonObject(with: Data(try rig.loam(["worktree", "list", "--json"]).utf8)) as? [[String: Any]] ?? []
        let stages = Dictionary(uniqueKeysWithValues: listed.compactMap { row -> (String, String)? in
            guard let id = (row["worktree"] as? [String: Any])?["id"] as? String, let stage = row["stage"] as? String else { return nil }
            return (id, stage)
        })
        try expect(stages[fixLogin.id] == "ready_to_merge" && stages[linkLabels.id] == "ready_to_merge"
                   && stages[nativePanel.id] == "waiting_for_review" && stages[localWork.id] == "not_pushed",
                   "the cache has the stages \(stages)")
        func ghCalls() throws -> Int {
            try String(contentsOf: rig.root.appendingPathComponent("gh-calls.jsonl"), encoding: .utf8).split(separator: "\n").count
        }
        let callsBeforeLaunch = try ghCalls()

        // The app gets the same fake gh. Only a refresh would call it. The refresh of ticket 108 is off
        // here, so this scenario shows that the marks and the row come from the cache.
        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: rig.environment.merging(ghEnvironment) { $1 }),
            state: rig.stateFile) { host in host.model.shipRefresh.run = { _ in } }
        let model = host.model
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == alpha }
        try await app.waitUntil("the app lists the 4 worktrees") { model.worktrees.values.joined().count == 4 }

        // 3. The Ready to merge row counts the ready worktrees of both plots.
        try await app.waitUntil("the Ready to merge row shows 2") { app.text(of: "attention-ready-to-merge") == "Ready to merge: 2" }
        try expect(AccessibilityProbe.shared.isEnabled("attention-ready-to-merge"), "the row with a count is not enabled")
        try expect(model.sidebar.readyToMerge.map(\.id) == [fixLogin.id, linkLabels.id],
                   "the ready worktrees are \(model.sidebar.readyToMerge.map(\.id))")

        // The marks of the rows of the active plot: the PR number, the stage in words, and the status line
        // of the stage, the same words as the Worktrees section (`StatusLine`).
        try await app.waitUntil("the marks of Alpha plot") {
            app.text(of: "worktree-\(fixLogin.id)")?.contains("#31, Ready to merge, 1 of 1 check passed, Approved") == true
                && app.text(of: "worktree-\(nativePanel.id)")?.contains("#32, Waiting for review, Review required") == true
        }
        app.screenshot("marks-and-row-night")
        NSApp.appearance = NSAppearance(named: .aqua)
        await app.sleep(1)
        app.screenshot("marks-and-row-day")
        NSApp.appearance = nil

        // 4. ⌘⇧L selects the first ready worktree, then the second in the other plot, then the first again.
        try pressExactMenuKey("l", [.command, .shift])
        try await app.waitUntil("⌘⇧L selects the first") {
            model.workspace.activePlotID == alpha && model.sidebar.selection == .worktree(fixLogin.id)
        }
        // The selected row shows as selected, and its neighbour does not.
        try await app.waitUntil("the first row shows as selected") {
            AccessibilityProbe.shared.isSelected("worktree-\(fixLogin.id)")
        }
        try expect(!AccessibilityProbe.shared.isSelected("worktree-\(nativePanel.id)"), "the other worktree row shows as selected")
        try pressExactMenuKey("l", [.command, .shift])
        try await app.waitUntil("⌘⇧L selects the second") {
            model.workspace.activePlotID == beta && model.sidebar.selection == .worktree(linkLabels.id)
        }
        try await app.waitUntil("the marks of Beta plot") {
            app.text(of: "worktree-\(linkLabels.id)")?.contains("#41, Ready to merge, 1 of 1 check passed, Approved") == true
                && app.text(of: "worktree-\(localWork.id)")?.contains("Not pushed") == true
        }
        app.screenshot("second-ready-worktree")
        try pressExactMenuKey("l", [.command, .shift])
        try await app.waitUntil("⌘⇧L selects the first again") {
            model.workspace.activePlotID == alpha && model.sidebar.selection == .worktree(fixLogin.id)
        }

        // A click on the row does the same as the key.
        try app.click("attention-ready-to-merge")
        try await app.waitUntil("a click on the row selects the second") {
            model.workspace.activePlotID == beta && model.sidebar.selection == .worktree(linkLabels.id)
        }

        // 5. Ship state is information (ADR 0007): no stage raises Needs you or Done, unread. The app read
        // the cache only, so the fake gh got no call after the rig's refresh.
        try expect(model.sidebar.needsYouCount == 0 && model.sidebar.doneUnreadCount == 0, "a stage raised an alert state")
        try expect(app.text(of: "attention-needs-you") == "Needs you", "the Needs you row counts a stage")
        try expect(try ghCalls() == callsBeforeLaunch, "the app called gh")

        // 6. Nothing is ready: the row stays, with no count, and does nothing.
        try ghState(ready: false).write(to: state, atomically: true, encoding: .utf8)
        try rig.loam(["worktree", "list", "--refresh"], extra: ghEnvironment)
        await model.reloadWorktrees()
        try await app.waitUntil("the row has no count") { app.text(of: "attention-ready-to-merge") == "Ready to merge" }
        try expect(!AccessibilityProbe.shared.isEnabled("attention-ready-to-merge"), "the row with no count is enabled")
        try expect(!model.goToNextReadyWorktree(), "the cycle found a worktree while none is ready")
        app.screenshot("none-ready")

        // 7. While gh is missing the core cannot name the stages, so the row goes.
        try rig.loam(["worktree", "list", "--refresh"], extra: ghEnvironment.merging(["LOAM_GH": rig.root.appendingPathComponent("no-gh").path]) { $1 })
        await model.reloadWorktrees()
        try await app.waitUntil("the row goes while gh is missing") { !app.exists("attention-ready-to-merge") }
        try expect(!model.sidebar.showsReadyToMerge, "the model shows the row while gh is missing")
    }
}
