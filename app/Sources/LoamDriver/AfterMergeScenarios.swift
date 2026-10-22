import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 113: after a merge on GitHub. It uses a temp `LOAM_HOME`, a temp git repo with a made-up
/// GitHub address, and the core's fake `gh` (`LOAM_DRIVER_FAKE_GH`) with the repo `example/widgets`. The scenario turns
/// PRs to MERGED in the state of the fake `gh`, as a merge on GitHub does, and asks for a refresh. It never touches
/// `~/.loam`, a real repo, or GitHub.
@MainActor
extension Scenarios {
    private static func expectMerge(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func afterMerge(_ app: DriverApp) async throws {
        do { try await afterMergeSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// What GitHub says about the PRs of `example/widgets`: four PRs, approved, with one passed check, all on the commit
    /// `head`. GitHub merged the PRs in `merged`. PR 145 has no head commit, as a PR in a cache from before Loam kept the
    /// head. The core then shows the Merged stage although the worktree has changed files, so the app must check them.
    private static func mergeGitHub(head: String, merged: Set<Int>) throws -> Data {
        func pull(_ number: Int, _ branch: String, title: String, head: String?) -> [String: Any] {
            var node: [String: Any] = [
                "number": number, "title": title, "url": "https://github.com/example/widgets/pull/\(number)",
                "state": merged.contains(number) ? "MERGED" : "OPEN", "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
                "reviewDecision": "APPROVED", "baseRefName": "main", "headRefName": branch, "commits": ["totalCount": 3],
            ]
            if let head { node["headRefOid"] = head }
            if merged.contains(number) {
                // Now, so the status line shows the time of day.
                let now = ISO8601DateFormatter().string(from: Date())
                node["mergedAt"] = now
                node["closedAt"] = now
            }
            return node
        }
        func detail(run: Int) -> [String: Any] {
            let check: [String: Any] = [
                "__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS", "isRequired": true,
                "startedAt": "2026-01-01T10:00:00Z", "completedAt": "2026-01-01T10:03:10Z",
                "detailsUrl": "https://github.com/example/widgets/actions/runs/\(run)/job/1",
                "checkSuite": ["workflowRun": ["databaseId": run, "workflow": ["name": "build"]]],
            ]
            return ["baseRef": ["compare": ["behindBy": 0]],
                    "commits": ["nodes": [["commit": ["statusCheckRollup": [
                        "state": "SUCCESS", "contexts": ["totalCount": 1, "nodes": [check]]]]]]],
                    "latestOpinionatedReviews": ["nodes": [["state": "APPROVED"]]], "reviewThreads": ["nodes": [Any]()]]
        }
        let state: [String: Any] = [
            "refs": ["link-labels", "fix-login", "rename-users", "native-panel"],
            "repository": ["mergeCommitAllowed": false, "squashMergeAllowed": true, "rebaseMergeAllowed": true,
                           "viewerDefaultMergeMethod": "SQUASH"],
            "pulls": [
                pull(142, "link-labels", title: "Link labels", head: head),
                pull(143, "fix-login", title: "Fix login", head: head),
                pull(144, "rename-users", title: "Rename users", head: head),
                pull(145, "native-panel", title: "Native panel", head: nil),
            ],
            "details": ["142": detail(run: 501), "143": detail(run: 502), "144": detail(run: 503), "145": detail(run: 504)],
        ]
        return try JSONSerialization.data(withJSONObject: state)
    }

    private static func afterMergeSteps(_ app: DriverApp) async throws {
        guard let fakeGH = ProcessInfo.processInfo.environment["LOAM_DRIVER_FAKE_GH"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_GH does not name the fake gh")
        }
        let rig = try PanelRig(outFolder: app.outFolder)
        let ghState = rig.root.appendingPathComponent("gh-state.json")
        let ghLog = rig.root.appendingPathComponent("gh-calls.jsonl")
        /// The shot waits for a callout to grow in, and for a toast to fade in.
        func settledShot(_ name: String) async throws {
            try await Task.sleep(for: .seconds(LoamTheme.durationSlow * 2))
            app.screenshot(name)
        }

        // 1. A repo with four worktrees. native-panel has 2 files that are not committed. The remote becomes a GitHub
        // address after the worktrees exist, so no git command asks the network.
        let plot = try rig.newPlot("Widgets plot")
        let widgets = try makeRepo(rig, named: "widgets")
        try rig.loam(["repo", "add", plot, widgets.path])
        let repoID = try (rig.show(plot)["repos"] as? [[String: Any]])?.first?["id"] as? String ?? { throw DriverFailure("no repo ID") }()
        let labels = try makeWorktree(rig, plot: plot, repo: widgets, name: "link-labels")
        let fix = try makeWorktree(rig, plot: plot, repo: widgets, name: "fix-login")
        let rename = try makeWorktree(rig, plot: plot, repo: widgets, name: "rename-users")
        let panel = try makeWorktree(rig, plot: plot, repo: widgets, name: "native-panel")
        for name in ["notes.txt", "todo.txt"] {
            try "draft\n".write(to: URL(fileURLWithPath: panel.path).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try git(widgets, ["remote", "set-url", "origin", "https://github.com/example/widgets.git"])
        let head = try headCommit(of: labels.path)
        try mergeGitHub(head: head, merged: []).write(to: ghState)
        try rig.loam(["set", plot, "where-it-stands", "Building the link labels."])

        let client = LoamClient(binary: rig.binary, environment: rig.environment.merging(try rig.neutralPrompt()) { $1 }.merging([
            "LOAM_GH": fakeGH, "LOAM_FAKE_GH_STATE": ghState.path, "LOAM_FAKE_GH_LOG": ghLog.path,
        ]) { $1 })
        // The timers are far away, so only the launch and the refreshes of this scenario ask GitHub.
        let host = try await app.launchApp(client: client, state: rig.stateFile, terminals: true) { host in
            host.model.shipRefresh.timing.activeInterval = .seconds(3600)
            host.model.shipRefresh.timing.otherInterval = .seconds(3600)
        }
        host.window.setFrame(NSRect(x: 80, y: 80, width: 1360, height: 820), display: true)
        let model = host.model
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }
        try await app.waitUntil("the stages") {
            [labels, fix, rename, panel].allSatisfy { model.worktreeStatus($0.id)?.stage == .readyToMerge }
        }
        func merge(_ numbers: Set<Int>) async throws {
            try mergeGitHub(head: head, merged: numbers).write(to: ghState)
            await model.refreshWorktrees(plot: plot)
        }
        func callout(_ id: String) -> String { app.text(of: "panel-merged-\(id)") ?? "" }

        // 2. A shell in link-labels, and the panel.
        model.openWorktreePane(try model.worktreeStatus(labels.id)?.worktree ?? { throw DriverFailure("no link-labels") }(), kind: .shell)
        let shell = try model.workspace.focusedPane ?? { throw DriverFailure("no focused pane") }()
        try await app.openPanel(host)

        // 3. GitHub merges #143. The repo asks: a callout at the top of the panel. Keep leaves the faded Merged row with its
        // Remove... pill, and the sidebar row shows the Merged symbol with the PR number.
        try await merge([143])
        try await app.waitUntil("the callout of fix-login") {
            callout(fix.id) == "#143 was merged on GitHub. Remove the worktree fix-login?"
        }
        try expectMerge(app.exists("panel-merged-keep-\(fix.id)") && app.exists("panel-merged-remove-\(fix.id)"), "the callout has no buttons")
        try app.click("panel-merged-keep-\(fix.id)")
        try await app.waitUntil("the callout goes, and the row stays with Remove") {
            !app.exists("panel-merged-\(fix.id)") && app.exists("panel-worktree-remove-\(fix.id)")
        }
        try expectMerge(FileManager.default.fileExists(atPath: fix.path), "Keep removed the worktree")
        try await settledShot("after-merge-kept-row")

        // 4. GitHub merges #142. A kept merge asks nothing again.
        try await merge([142, 143])
        try await app.waitUntil("the callout of link-labels") {
            callout(labels.id) == "#142 was merged on GitHub. Remove the worktree link-labels?"
        }
        try expectMerge(!app.exists("panel-merged-\(fix.id)"), "the kept merge asks again")
        try expectMerge(model.workspace.allPaneIDs.contains(shell), "Ask closed the shell")
        try await settledShot("after-merge-ask")

        // 5. Remove worktree closes the shell, removes the worktree and its branch, and gives Where it stands the keys with
        // the sentence about the merge selected.
        let sentence = "Merged #142 Link labels."
        let before = try rig.lastChangeID(plot)
        try app.click("panel-merged-remove-\(labels.id)")
        try await app.waitUntil("the worktree goes", timeout: 30) {
            model.worktreeStatus(labels.id) == nil && !FileManager.default.fileExists(atPath: labels.path)
        }
        try expectMerge(!model.workspace.allPaneIDs.contains(shell), "the shell of link-labels is still open")
        try await app.waitUntil("Where it stands has the keys with the sentence selected") {
            guard let editor = host.window.firstResponder as? NSTextView else { return false }
            return editor.string == "\(sentence) Building the link labels."
                && editor.selectedRange() == NSRange(location: 0, length: (sentence as NSString).length)
        }
        try expectMerge(!app.exists("panel-merged-\(labels.id)"), "the callout stays after the removal")
        try expectMerge(try rig.lastChangeID(plot) == before, "Where it stands saved with no Command-Return")
        try await settledShot("after-merge-where-selected")
        let branches = try rig.loam(["worktree", "list", plot, "--json"])
        try expectMerge(!branches.contains("link-labels"), "the core still lists link-labels")

        // Escape leaves the field and keeps the draft. Command-Return in the field saves it as one change.
        app.press(.escape)
        try await app.waitUntil("the field lets the keys go") { !(host.window.firstResponder is NSTextView) }
        try expectMerge(model.panel.isDirty(.whereItStands) && app.exists("panel-save-whereItStands"), "Escape dropped the draft")
        try expectMerge(try rig.lastChangeID(plot) == before, "Escape saved Where it stands")
        try expectMerge(AccessibilityProbe.shared.focus("panel-whereItStands"), "the field took no focus")
        try await app.waitUntil("the field has the keys") { host.window.firstResponder is NSTextView }
        app.press(.returnKey, flags: .command)
        try await app.waitUntil("Where it stands is saved") {
            (try? rig.show(plot)["where_it_stands"] as? String) == "\(sentence) Building the link labels."
        }

        // 6. The setting: Repo actions, After a merge on GitHub, Remove the worktree.
        try await setAfterMergeInTheMenu(app, host, repo: repoID)
        try await app.waitUntil("the repo says remove") { model.panel.plot?.repos.first?.afterMerge == .remove }

        // 7. GitHub merges #144 and #145. rename-users is clean, so it goes with a toast. native-panel has changed files,
        // so it asks, and keeps its files.
        try await merge([142, 143, 144, 145])
        try await app.waitUntil("the toast of the removal", timeout: 20) {
            app.text(of: "action-bar-toast")?.contains("#144 was merged on GitHub. Loam removed the worktree rename-users.") == true
        }
        try expectMerge(!FileManager.default.fileExists(atPath: rename.path), "the folder of rename-users is still there")
        try await app.waitUntil("the callout of native-panel") {
            callout(panel.id) == "#145 was merged on GitHub. Remove the worktree native-panel?"
        }
        try expectMerge(model.worktreeStatus(panel.id)?.changed == 2, "native-panel lost its changes")
        try expectMerge(FileManager.default.fileExists(atPath: URL(fileURLWithPath: panel.path).appendingPathComponent("notes.txt").path),
                        "the files of native-panel are gone")
        try expectMerge(app.exists("panel-worktree-remove-\(fix.id)") && !app.exists("panel-merged-\(fix.id)"),
                        "the kept worktree changed with the setting")
        try await settledShot("after-merge-removed")
    }

    /// The menus that AppKit opened, first the menu and then its submenus.
    @MainActor private final class OpenMenus {
        var menus: [NSMenu] = []
    }

    /// Opens the right-click menu of a Repos row and its submenu "After a merge on GitHub", shoots them, and picks
    /// "Remove the worktree". An app in the background takes no keys in a menu, so the items get the accessibility API,
    /// as VoiceOver uses it. The shot of the window holds only the parts of the menus that are inside its frame, so the
    /// window moves to the right edge of the screen first. Then the menus open over the window.
    private static func setAfterMergeInTheMenu(_ app: DriverApp, _ host: AppHost, repo: String) async throws {
        if let screen = host.window.screen?.visibleFrame {
            host.window.setFrameOrigin(NSPoint(x: screen.maxX - host.window.frame.width, y: host.window.frame.minY))
        }
        await app.sleep(0.3)
        let row = "panel-repo-\(repo)"
        guard let frame = AccessibilityProbe.shared.node(row)?.frame else { throw DriverFailure("no Repos row \(repo)") }
        // The accessibility frame has its origin at the top left of the main screen, AppKit at the bottom left.
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = host.window.convertPoint(fromScreen: NSPoint(x: frame.minX + 40, y: screenHeight - frame.midY))
        let open = OpenMenus()
        let begin = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            // AppKit posts it on the main thread, from the menu that begins.
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated { if let menu { open.menus.append(menu) } }
        }
        defer {
            NotificationCenter.default.removeObserver(begin)
            open.menus.first?.cancelTracking()
        }
        app.postRightMouseDown(at: point)
        try await app.waitUntil("the Repo actions menu opens") { !open.menus.isEmpty }
        let menu = open.menus[0]
        try expectMerge(menu.items.map(\.title) == ["After a merge on GitHub", "", "Remove repo"], "the menu holds \(menu.items.map(\.title))")
        try expectMerge(menu.items[1].isSeparatorItem, "no divider above Remove repo")
        let submenu = try menu.items[0].submenu ?? { throw DriverFailure("After a merge on GitHub has no submenu") }()
        try expectMerge(submenu.items.map(\.title) == ["Ask", "Remove the worktree", "Do nothing"], "the submenu holds \(submenu.items.map(\.title))")
        try expectMerge(submenu.items.map(\.state) == [.on, .off, .off], "Ask is not the checked item")

        // As a hover does, the selected item opens its submenu on a press.
        let item = try menuItem("After a merge on GitHub")
        AXUIElementSetAttributeValue(item, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        try await app.waitUntil("the submenu opens") { menuWindows() > 1 }
        try await Task.sleep(for: .seconds(LoamTheme.durationBase * 2))
        app.screenshot("after-merge-setting")
        guard AXUIElementPerformAction(try menuItem("Remove the worktree"), kAXPressAction as CFString) == .success else {
            throw DriverFailure("Remove the worktree took no press")
        }
        Log.line("press menu item Remove the worktree")
        try await app.waitUntil("the menu closes") { menuWindows() == 0 }
    }

    /// The windows of the menus of the app that are open.
    private static func menuWindows() -> Int {
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return listed.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int ?? 0) >= level
        }.count
    }

    /// The item with this title in a menu of the app that is open, through the accessibility API.
    private static func menuItem(_ title: String) throws -> AXUIElement {
        func string(_ element: AXUIElement, _ attribute: String) -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return value as? String ?? ""
        }
        var queue = [AXUIElementCreateApplication(getpid())]
        var visited = 0
        while !queue.isEmpty, visited < 20_000 {
            let element = queue.removeFirst()
            visited += 1
            if string(element, kAXRoleAttribute) == kAXMenuItemRole as String, string(element, kAXTitleAttribute) == title {
                return element
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success {
                queue += (children as? [AXUIElement]) ?? []
            }
        }
        throw DriverFailure("no open menu has the item \(title)")
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
}
