import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 109: the PR popover, the chip in the action bar, the PR number in the pane
/// header, and the worktree entries of the ⌘J menu and the switcher. It uses a temp `LOAM_HOME`, a temp git
/// repo with a made-up GitHub address, and the core's fake `gh` (`LOAM_DRIVER_FAKE_GH`). The app calls
/// `gh` through `loam` only, so the fake `gh` log shows what the popover asked for. It never touches
/// `~/.loam`, a real repo, or GitHub.
@MainActor
extension Scenarios {
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func prPopover(_ app: DriverApp) async throws {
        do { try await prPopoverSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// The GitHub that the fake `gh` answers from, for the repo `example/widgets`: PR 16 of the branch
    /// `native-panel` has 2 failed checks of 3 (the runs 301 and 302) and is 3 commits behind main. PR 22
    /// of the branch `link-labels` passes its check and has an approval, so it is ready to merge.
    private static func popoverGitHub() throws -> Data {
        func pull(_ number: Int, _ branch: String, title: String, mergeState: String, review: String) -> [String: Any] {
            ["number": number, "title": title, "url": "https://github.com/example/widgets/pull/\(number)",
             "state": "OPEN", "mergeable": "MERGEABLE", "mergeStateStatus": mergeState, "reviewDecision": review,
             "baseRefName": "main", "headRefName": branch, "headRefOid": String(repeating: "a", count: 40),
             "commits": ["totalCount": 2]]
        }
        func check(_ name: String, _ conclusion: String, run: Int) -> [String: Any] {
            ["__typename": "CheckRun", "name": name, "status": "COMPLETED", "conclusion": conclusion, "isRequired": true,
             "startedAt": "2026-01-01T10:00:00Z", "completedAt": "2026-01-01T10:03:10Z",
             "detailsUrl": "https://github.com/example/widgets/actions/runs/\(run)/job/1",
             "checkSuite": ["workflowRun": ["databaseId": run, "workflow": ["name": name]]]]
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
                pull(16, "native-panel", title: "Native panel", mergeState: "BEHIND", review: "REVIEW_REQUIRED"),
                pull(22, "link-labels", title: "Link labels", mergeState: "CLEAN", review: "APPROVED"),
            ],
            "details": [
                "16": detail(state: "FAILURE", checks: [check("build", "SUCCESS", run: 300), check("lint", "FAILURE", run: 301),
                                                        check("test", "FAILURE", run: 302)], behind: 3, reviews: []),
                "22": detail(state: "SUCCESS", checks: [check("build", "SUCCESS", run: 303)], behind: 0, reviews: [["state": "APPROVED"]]),
            ],
        ]
        return try JSONSerialization.data(withJSONObject: state)
    }

    private static func prPopoverSteps(_ app: DriverApp) async throws {
        guard let fakeGH = ProcessInfo.processInfo.environment["LOAM_DRIVER_FAKE_GH"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_GH does not name the fake gh")
        }
        let rig = try PanelRig(outFolder: app.outFolder)
        let ghState = rig.root.appendingPathComponent("gh-state.json")
        let ghLog = rig.root.appendingPathComponent("gh-calls.jsonl")
        try popoverGitHub().write(to: ghState)

        // The calls that reached the fake `gh`: the arguments, and the variables of a query.
        func calls() -> [(args: [String], variables: [String: Any])] {
            ((try? String(contentsOf: ghLog, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
                guard let call = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
                return (call["args"] as? [String] ?? [], call["variables"] as? [String: Any] ?? [:])
            }
        }
        /// The first query of a refresh names `q0`. A refresh of one worktree names no `q1`.
        func refreshes(ofOneWorktree one: Bool) -> Int {
            calls().filter { $0.variables["q0"] != nil && ($0.variables["q1"] == nil) == one }.count
        }
        func commands(_ words: [String]) -> Int { calls().filter { Array($0.args.prefix(words.count)) == words }.count }
        /// True when a refresh of one worktree came after the last call of the command. `loam worktree rerun` reads
        /// the PR itself first, so a count of refreshes would not tell the refresh of the popover from that read.
        func refreshed(after words: [String]) -> Bool {
            let all = calls()
            guard let last = all.lastIndex(where: { Array($0.args.prefix(words.count)) == words }) else { return false }
            return all[(last + 1)...].contains { $0.variables["q0"] != nil && $0.variables["q1"] == nil }
        }

        // 1. A repo with three worktrees: two with a PR, and one with local work. The remote becomes a
        // GitHub address after the worktrees exist, so no git command asks the network.
        let plot = try rig.newPlot("Popover plot")
        let widgets = try makeRepo(rig, named: "widgets")
        try rig.loam(["repo", "add", plot, widgets.path])
        let labels = try makeWorktree(rig, plot: plot, repo: widgets, name: "link-labels")
        let panel = try makeWorktree(rig, plot: plot, repo: widgets, name: "native-panel")
        let local = try makeWorktree(rig, plot: plot, repo: widgets, name: "local-work")
        try git(widgets, ["remote", "set-url", "origin", "https://github.com/example/widgets.git"])

        // The client's environment is the pane's environment. The shells read an empty `.zshrc` of the fake HOME, so
        // the real startup files of the Mac do not set their prompt or their title.
        try "".write(to: rig.fakeHome.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let client = LoamClient(binary: rig.binary, environment: rig.environment.merging([
            "LOAM_GH": fakeGH, "LOAM_FAKE_GH_STATE": ghState.path, "LOAM_FAKE_GH_LOG": ghLog.path,
            "ZDOTDIR": rig.fakeHome.path,
        ]) { $1 })
        // The timers are far away, so only the launch and the popover make a refresh.
        let host = try await app.launchApp(client: client, state: rig.stateFile, terminals: true) { host in
            host.model.shipRefresh.timing.activeInterval = .seconds(3600)
            host.model.shipRefresh.timing.otherInterval = .seconds(3600)
        }
        let model = host.model
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }
        try await app.waitUntil("the launch refresh") { refreshes(ofOneWorktree: false) == 1 }
        try await app.waitUntil("the stages") {
            model.worktreeStatus(panel.id)?.stage == .checksFailed && model.worktreeStatus(labels.id)?.stage == .readyToMerge
        }
        func worktree(_ made: (id: String, path: String)) throws -> Worktree {
            try model.worktreeStatus(made.id)?.worktree ?? { throw DriverFailure("the list has no worktree \(made.id)") }()
        }
        func focusedWorktreeID() -> String? { model.focusedWorktree?.id }
        func terminal() throws -> TerminalSurfaceView {
            guard let pane = model.workspace.focusedPane, let view = host.paneView(pane) as? TerminalSurfaceView else {
                throw DriverFailure("the focused pane has no terminal")
            }
            return view
        }
        func terminalHasTheKeys() -> Bool {
            model.workspace.focusedPane.map { host.window.firstResponder === host.paneView($0) } ?? false
        }

        // 2. The chip shows for a pane in a worktree with a PR, and for no other pane.
        await model.openShellTab()
        try await app.waitUntil("the shell in the main checkout has the keys") { terminalHasTheKeys() }
        try check(!app.exists("action-bar-pr-chip"), "a pane in the main checkout shows a chip")
        model.openWorktreePane(try worktree(local), kind: .shell)
        try await app.waitUntil("the shell in local-work") { focusedWorktreeID() == local.id && terminalHasTheKeys() }
        await app.sleep(0.5)
        try check(!app.exists("action-bar-pr-chip"), "a worktree with no PR shows a chip")
        model.openWorktreePane(try worktree(panel), kind: .shell)
        try await app.waitUntil("the shell in native-panel") { focusedWorktreeID() == panel.id && terminalHasTheKeys() }
        let panelPane = try model.workspace.focusedPane ?? { throw DriverFailure("no focused pane") }()
        try await app.waitUntil("the chip") { app.exists("action-bar-pr-chip") }
        let chip = app.text(of: "action-bar-pr-chip") ?? ""
        try check(chip.contains("#16") && chip.contains("Checks failed"), "the chip reads \(chip)")
        try check(!app.exists("pr-popover"), "a popover shows with no click")
        app.screenshot("pr-chip")

        // 3. A click on the chip opens the popover for the worktree and asks GitHub about that worktree
        // only. The rows, the failed checks and the buttons come from the row; no primary button shows
        // (tickets 110 and 112 build them).
        try app.click("action-bar-pr-chip")
        try await app.waitUntil("the popover opens") { app.exists("pr-popover") && model.prPopover.worktreeID == panel.id }
        try await app.waitUntil("the popover asked about the worktree") { refreshes(ofOneWorktree: true) == 1 && !model.prPopover.isRefreshing }
        try check(refreshes(ofOneWorktree: false) == 1, "the popover refreshed the whole plot")
        try check(app.text(of: "pr-popover-title") == "#16 Native panel", "the title reads \(app.text(of: "pr-popover-title") ?? "nothing")")
        try check(app.text(of: "pr-popover-stage")?.contains("Checks failed") == true, "the stage reads \(app.text(of: "pr-popover-stage") ?? "nothing")")
        try await app.waitUntil("the update time") { app.text(of: "pr-popover-updated")?.hasPrefix("Updated ") == true }
        for (id, words) in [("checks", "2 failed"), ("review", "Review required"), ("base", "3 commits behind main"), ("conflicts", "None")] {
            let text = app.text(of: "pr-popover-row-\(id)") ?? "nothing"
            try check(text.contains(words), "the \(id) row reads \(text)")
        }
        try check(app.exists("pr-popover-failed-checks") && app.exists("pr-popover-check-0") && app.exists("pr-popover-check-1")
                  && !app.exists("pr-popover-check-2"), "the failed checks do not show as 2 rows")
        try check(app.text(of: "pr-popover-check-0")?.contains("lint") == true && app.text(of: "pr-popover-check-1")?.contains("test") == true,
                  "the checks read \(app.text(of: "pr-popover-check-0") ?? "nothing") and \(app.text(of: "pr-popover-check-1") ?? "nothing")")
        try check(app.exists("pr-popover-log-0") && app.exists("pr-popover-log-1"), "a failed check has no Log link")
        try check(app.exists("pr-popover-rerun-failed") && app.exists("pr-popover-update-branch") && app.exists("pr-popover-open-on-github"),
                  "a button is missing")
        try check(!app.exists("pr-popover-copy-branch-name"), "a worktree with a PR offers Copy branch name")
        try check(!app.exists("pr-popover-primary"), "a primary button shows before tickets 110 and 112")
        // The popover opens above the chip and starts at its left edge, or as far left as the window edge allows. The
        // frame of `pr-popover` is the whole overlay, so the buttons give the left and the bottom edge of the card.
        func frame(_ id: String) throws -> CGRect {
            try AccessibilityProbe.shared.node(id)?.frame ?? { throw DriverFailure("no frame for \(id)") }()
        }
        let (chipFrame, firstButton, lastButton) = try (frame("action-bar-pr-chip"), frame("pr-popover-rerun-failed"), frame("pr-popover-open-on-github"))
        let cardPadding: CGFloat = 24
        try check(lastButton.maxY <= chipFrame.minY - PopoverPlacement.gap, "the popover does not stand above the chip: \(chipFrame) \(lastButton)")
        try check(abs(firstButton.minX - chipFrame.minX) <= cardPadding, "the popover does not start at the chip: \(chipFrame) \(firstButton)")
        app.screenshot("pr-popover")

        // 4. Re-run failed goes to `gh` through `loam`: one `gh run rerun --failed` for each run. The popover
        // says what GitHub did, and then asks about the worktree again.
        try app.click("pr-popover-rerun-failed")
        try await app.waitUntil("the re-run note") { app.text(of: "pr-popover-note") == "GitHub runs the failed checks of 2 runs again." }
        try check(commands(["run", "rerun", "301", "--failed"]) == 1 && commands(["run", "rerun", "302", "--failed"]) == 1,
                  "gh got \(calls().map { $0.args.joined(separator: " ") })")
        try await app.waitUntil("the refresh after the re-run") {
            refreshed(after: ["run", "rerun", "302", "--failed"]) && !model.prPopover.isRefreshing
        }
        try check(app.exists("pr-popover"), "the re-run closed the popover")

        // Update branch: `gh pr update-branch`, then a refresh.
        try app.click("pr-popover-update-branch")
        try await app.waitUntil("the update note") { app.text(of: "pr-popover-note")?.contains("GitHub brought the PR up to date with main.") == true }
        try check(commands(["pr", "update-branch", "16"]) == 1, "gh got \(calls().map { $0.args.joined(separator: " ") })")
        try await app.waitUntil("the refresh after the update") {
            refreshed(after: ["pr", "update-branch", "16"]) && !model.prPopover.isRefreshing
        }
        try check(refreshes(ofOneWorktree: false) == 1, "a button refreshed the whole plot")

        // 5. Escape closes the popover, and the keys go back to the terminal.
        app.press(.escape)
        try await app.waitUntil("Escape closes the popover") { !app.exists("pr-popover") && !model.prPopover.isOpen }
        try await app.waitUntil("the terminal has the keys again") { terminalHasTheKeys() }
        let shell = try terminal()
        try app.type("echo $((40+2))")
        app.press(.returnKey)
        try await app.waitUntil("the terminal took the keys") { app.lines(shell).contains("42") }

        // 6. A popover that opens above a field of the panel gives the keys back to the field. The field keeps
        // its text and its selection.
        try await app.openPanel(host)
        try app.fill("panel-whereItStands", with: "draft")
        try check(AccessibilityProbe.shared.isFocused("panel-whereItStands"), "the field has no focus")
        try app.click("panel-worktree-\(panel.id)")
        try await app.waitUntil("the row opens the popover") { app.exists("pr-popover") && model.prPopover.worktreeID == panel.id }
        try await app.waitUntil("the popover is done") { !model.prPopover.isRefreshing }
        try check(!(app.window.firstResponder is TerminalSurfaceView), "the popover gave the keys to the terminal")
        app.press(.escape)
        try await app.waitUntil("Escape closes the popover again") { !app.exists("pr-popover") }
        try await app.waitUntil("the field has the keys again") { AccessibilityProbe.shared.isFocused("panel-whereItStands") }
        try app.type("more")
        try await app.waitUntil("the keys went into the field") { app.text(of: "panel-whereItStands") == "draftmore" }
        try app.click("panel-revert-whereItStands")
        try await app.waitUntil("Revert drops the draft") { !app.exists("panel-revert-whereItStands") }

        // 7. ⌘⇧L goes to the ready worktree and opens its popover. It has no failed checks, so it has no
        // Re-run failed and no list. The chip in the bar is the PR of the focused pane, which is another worktree, so
        // the popover opens at the left end of the bar and not at that chip.
        try pressExactMenuKey("l", [.command, .shift])
        try await app.waitUntil("⌘⇧L opens the popover of the ready worktree") {
            app.exists("pr-popover") && model.prPopover.worktreeID == labels.id && model.sidebar.selection == .worktree(labels.id)
        }
        try await app.waitUntil("the popover is done") { !model.prPopover.isRefreshing }
        try check(app.text(of: "pr-popover-title") == "#22 Link labels", "the title reads \(app.text(of: "pr-popover-title") ?? "nothing")")
        try check(app.text(of: "pr-popover-stage")?.contains("Ready to merge") == true, "the stage reads \(app.text(of: "pr-popover-stage") ?? "nothing")")
        try check(app.text(of: "pr-popover-row-review")?.contains("Approved") == true, "the review row reads \(app.text(of: "pr-popover-row-review") ?? "nothing")")
        try check(!app.exists("pr-popover-failed-checks") && !app.exists("pr-popover-rerun-failed") && !app.exists("pr-popover-update-branch"),
                  "a passing PR shows failed-check controls")
        try check(app.exists("pr-popover-open-on-github") && !app.exists("pr-popover-primary"), "the buttons are wrong")
        let (plotName, readyButton) = try (frame("action-bar-plot"), frame("pr-popover-open-on-github"))
        try check(abs(readyButton.minX - plotName.minX) <= cardPadding, "the popover does not open at the left end of the bar: \(plotName) \(readyButton)")
        app.screenshot("pr-popover-ready")
        app.press(.escape)
        try await app.waitUntil("Escape closes the popover of the ready worktree") { !app.exists("pr-popover") }

        // 8. The switcher finds a worktree with a PR by its number, and Return opens its popover.
        try await openPopoverSwitcher(app)
        try app.fill("switcher-field", with: "#22")
        try await app.waitUntil("the worktree row", timeout: 5) { app.text(of: "switcher-row-0")?.hasPrefix("link-labels") == true }
        try await app.waitUntil("the preview of the worktree", timeout: 5) {
            app.text(of: "switcher-preview-caption") == "Worktree \u{00B7} Ready to merge" && app.text(of: "switcher-footer-action") == "Show pull request"
        }
        app.screenshot("pr-switcher")
        app.press(.returnKey)
        try await app.waitUntil("Return opens the popover") { !app.exists("switcher-field") && app.exists("pr-popover") && model.prPopover.worktreeID == labels.id }
        app.press(.escape)
        try await app.waitUntil("Escape closes that popover") { !app.exists("pr-popover") }

        // 9. A row of the sidebar has the action "Show pull request".
        try app.perform("Show pull request", on: "worktree-\(labels.id)")
        try await app.waitUntil("the sidebar action opens the popover") { app.exists("pr-popover") && model.prPopover.worktreeID == labels.id }
        app.press(.escape)
        try await app.waitUntil("Escape closes the popover from the sidebar") { !app.exists("pr-popover") }
        try check(!AccessibilityProbe.shared.performAction("worktree-\(local.id)", named: "Show pull request"), "a worktree with no PR has the action")

        // 10. The ⌘J menu of a pane in a worktree has the worktree section: Show pull request opens the popover,
        // and Refresh asks GitHub about the worktree without one.
        model.goToPane(panelPane)
        try await app.waitUntil("the shell of native-panel has the keys") { terminalHasTheKeys() && focusedWorktreeID() == panel.id }
        app.press(letter: "j", flags: .command)
        try await app.waitUntil("the menu opens") { app.exists("actions-menu") }
        try await app.waitUntil("the menu has the worktree rows") { app.exists("actions-row-Show pull request") && app.exists("actions-row-Refresh") }
        app.screenshot("pr-actions-menu")
        try await app.waitUntil("the search field has the keys") { host.window.firstResponder is NSTextView }
        try app.type("pull request")
        try await app.waitUntil("the filter leaves Show pull request") { app.exists("actions-row-Show pull request") && !app.exists("actions-row-Refresh") }
        app.press(.returnKey)
        try await app.waitUntil("Return opens the popover") { !app.exists("actions-menu") && app.exists("pr-popover") && model.prPopover.worktreeID == panel.id }
        try await app.waitUntil("the popover is done") { !model.prPopover.isRefreshing }
        app.press(.escape)
        try await app.waitUntil("Escape closes the popover from the menu") { !app.exists("pr-popover") }
        try await app.waitUntil("the terminal has the keys after the menu") { terminalHasTheKeys() }
        let narrowBeforeRefresh = refreshes(ofOneWorktree: true)
        app.press(letter: "j", flags: .command)
        try await app.waitUntil("the menu opens again") { app.exists("actions-menu") }
        try await app.waitUntil("the search field has the keys again") { host.window.firstResponder is NSTextView }
        try app.type("refresh")
        try await app.waitUntil("the filter leaves Refresh") { app.exists("actions-row-Refresh") && !app.exists("actions-row-Show pull request") }
        app.press(.returnKey)
        try await app.waitUntil("Return runs the refresh") { !app.exists("actions-menu") && refreshes(ofOneWorktree: true) == narrowBeforeRefresh + 1 }
        try check(!app.exists("pr-popover"), "Refresh opened the popover")
        try await app.waitUntil("the terminal has the keys after the refresh") { terminalHasTheKeys() }

        // 11. The header of a pane in a split tab names the branch and then the PR, in a label of its own that is
        // never cut. The new pane runs in no worktree.
        model.split(.sideBySide)
        let splitPane = try model.workspace.focusedPane ?? { throw DriverFailure("no focused pane after the split") }()
        try await app.waitUntil("the header of the first pane") { app.text(of: "pane-branch-\(panelPane.uuidString)") == "native-panel" }
        try check(app.text(of: "pane-pr-\(panelPane.uuidString)") == "#16", "the PR in the header reads \(app.text(of: "pane-pr-\(panelPane.uuidString)") ?? "nothing")")
        let (branchFrame, numberFrame) = try (frame("pane-branch-\(panelPane.uuidString)"), frame("pane-pr-\(panelPane.uuidString)"))
        // The number stands right after the branch: nearer to it than the branch stands to the title.
        try check(numberFrame.minX >= branchFrame.maxX && numberFrame.minX - branchFrame.maxX < PaneHeaderLayout.gap,
                  "the PR does not follow the branch: \(branchFrame) \(numberFrame)")
        try check(!app.exists("pane-branch-\(splitPane.uuidString)") && !app.exists("pane-pr-\(splitPane.uuidString)"),
                  "a pane in no worktree names a branch or a PR")
        app.screenshot("pr-pane-header")

        // 12. A popover closes when the focus moves to another pane: it belongs to the pane that opened it.
        model.goToPane(panelPane)
        try await app.waitUntil("the first pane has the keys") { focusedWorktreeID() == panel.id && terminalHasTheKeys() }
        model.openPullRequest(panel.id)
        try await app.waitUntil("the popover opens again") { app.exists("pr-popover") }
        model.goToPane(splitPane)
        try await app.waitUntil("a move to another pane closes the popover") { !app.exists("pr-popover") && !model.prPopover.isOpen }
        // The popover closed at once after it opened, and it does not take the keys back from the new pane.
        try await app.waitUntil("the terminal of the new pane has the keys") { terminalHasTheKeys() }
        await app.sleep(0.3)
        try check(terminalHasTheKeys(), "the closed popover took the keys")

        // 13. The popover follows the control that opened it: the mark of a sidebar row. A resize of the window and
        // a drag of the sidebar divider move the mark, and the card moves with it. A hidden sidebar hides the mark, so
        // the popover closes.
        let sidebarRow = "worktree-\(panel.id)"
        try app.perform("Show pull request", on: sidebarRow)
        try await app.waitUntil("the mark opens the popover") { app.exists("pr-popover-title") && model.prPopover.worktreeID == panel.id }
        try await app.waitUntil("the popover of the mark is done") { !model.prPopover.isRefreshing }
        /// Where the title of the card stands from the trailing edge of the row, where the mark is.
        func cardFromMark() -> CGPoint? {
            guard let row = try? frame(sidebarRow), let title = try? frame("pr-popover-title") else { return nil }
            return CGPoint(x: title.minX - row.maxX, y: title.minY - row.minY)
        }
        let atMark = try cardFromMark() ?? { throw DriverFailure("no card at the mark") }()
        // The window grows or shrinks at its top edge, which moves the row, on the side that keeps the card where it is:
        // a card above the mark keeps its room when the window is shorter, a card below when it is taller.
        let (resizeStep, dragStep): (CGFloat, CGFloat) = (80, 40)
        let cardAbove = atMark.y < 0
        let rowBeforeResize = try frame(sidebarRow)
        var resized = host.window.frame
        resized.size.height += cardAbove ? -resizeStep : resizeStep
        host.window.setFrame(resized, display: true)
        try await app.waitUntil("the resize moves the row") { (try? frame(sidebarRow))?.minY != rowBeforeResize.minY }
        try await app.waitUntil("the card follows the mark after a resize") { cardFromMark() == atMark }
        let split = try host.window.contentViewController as? NSSplitViewController ?? { throw DriverFailure("no split view") }()
        let sidebarWidth = split.splitViewItems.first?.viewController.view.frame.width ?? 0
        let rowBeforeDrag = try frame(sidebarRow)
        split.splitView.setPosition(sidebarWidth + dragStep, ofDividerAt: 0)
        try await app.waitUntil("the divider moves the mark") { (try? frame(sidebarRow))?.maxX != rowBeforeDrag.maxX }
        try await app.waitUntil("the card follows the mark after a drag of the divider") { cardFromMark() == atMark }
        try app.pressMenuKey("b")
        try await app.waitUntil("a hidden sidebar closes the popover of its mark") { !app.exists("pr-popover") && !model.prPopover.isOpen }
        try await app.waitUntil("the terminal has the keys after the sidebar hid") { terminalHasTheKeys() }

        // 14. A row of the Worktrees section that hides with the plot panel closes its popover too, and the keys go back
        // to the terminal.
        try app.click("panel-worktree-\(panel.id)")
        try await app.waitUntil("the row opens the popover again") { app.exists("pr-popover") && model.prPopover.worktreeID == panel.id }
        try await app.waitUntil("the popover of the row is done") { !model.prPopover.isRefreshing }
        try app.pressMenuKey("i")
        try await app.waitUntil("a hidden panel closes the popover of its row") { !app.exists("pr-popover") && !model.prPopover.isOpen }
        try await app.waitUntil("the terminal has the keys after the panel hid") { terminalHasTheKeys() }

        // 15. A field of the panel holds the keys when the popover opens, and the panel hides while the popover
        // shows. The popover opens from the action bar, so it outlives the panel. When it closes, the hidden field
        // gets no keys back and the terminal has them.
        try await app.openPanel(host)
        try app.fill("panel-whereItStands", with: "held")
        try check(AccessibilityProbe.shared.isFocused("panel-whereItStands"), "the field has no focus")
        model.openPullRequest(panel.id)
        try await app.waitUntil("the popover opens over the field") { app.exists("pr-popover") && model.prPopover.worktreeID == panel.id }
        try check(!(host.window.firstResponder is TerminalSurfaceView), "the popover gave the keys to the terminal")
        try app.pressMenuKey("i")
        try await app.waitUntil("the panel hides") { !model.panel.visible && !app.exists("panel-whereItStands") }
        try check(app.exists("pr-popover"), "a hidden panel closed a popover that does not point at it")
        app.press(.escape)
        try await app.waitUntil("Escape closes the popover over the hidden panel") { !app.exists("pr-popover") && !model.prPopover.isOpen }
        try await app.waitUntil("the terminal has the keys, not the hidden field") { terminalHasTheKeys() }
        await app.sleep(0.3)
        try check(terminalHasTheKeys(), "the hidden field took the keys back")
    }

    private static func openPopoverSwitcher(_ app: DriverApp) async throws {
        try app.pressMenuKey("p", flags: .command)
        try await app.waitUntil("the switcher shows", timeout: 5) { app.exists("switcher-field") }
    }
}
