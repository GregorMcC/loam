import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 110: Send to session. The PR popover types a fix prompt into the session of a
/// worktree, and you press Return. It offers Copy prompt while the session is busy and after a paste or a key that
/// the session did not take, and it starts a session when the worktree has none. The sessions are the core's fake `claude` in hook mode
/// (`LOAM_DRIVER_FAKE_CLAUDE`), which writes each prompt that it gets to a file. GitHub is the core's fake `gh`
/// (`LOAM_DRIVER_FAKE_GH`) with a made-up repo. It uses a temp `LOAM_HOME` and never touches `~/.loam`, a real
/// repo, GitHub, or your clipboard.
@MainActor
extension Scenarios {
    private static func expectSend(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func sendToSession(_ app: DriverApp) async throws {
        do { try await sendSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// How many times the input hook of a terminal ran.
    private final class InputCount {
        var value = 0
    }

    /// The prompts of the two PRs, as the ticket words them.
    private static let failuresPrompt = "Checks failed on #139: lint / swiftformat, test / macos-26. Run `gh pr checks 139`, read the failing logs, fix them, and push."
    private static let reviewPrompt = "PR #137 has changes requested, with 3 review comments. Run `gh pr view 137 --comments`, address each comment, and push."
    /// How long a turn of the fake `claude` takes. The busy steps run inside one turn.
    private static let turnSeconds = 12.0

    /// The GitHub that the fake `gh` answers from, for the made-up repo `example/widgets`: PR 139 of the branch
    /// `native-panel` failed 2 of its 3 checks, and PR 137 of the branch `switcher-width` has changes requested with 3
    /// open review threads.
    private static func sendGitHub() throws -> Data {
        func pull(_ number: Int, _ branch: String, title: String, mergeState: String, review: String) -> [String: Any] {
            ["number": number, "title": title, "url": "https://github.com/example/widgets/pull/\(number)",
             "state": "OPEN", "mergeable": "MERGEABLE", "mergeStateStatus": mergeState, "reviewDecision": review,
             "baseRefName": "main", "headRefName": branch, "headRefOid": String(repeating: "b", count: 40),
             "commits": ["totalCount": 3]]
        }
        func check(_ workflow: String, _ name: String, _ conclusion: String, run: Int) -> [String: Any] {
            ["__typename": "CheckRun", "name": name, "status": "COMPLETED", "conclusion": conclusion, "isRequired": true,
             "startedAt": "2026-01-01T10:00:00Z", "completedAt": "2026-01-01T10:02:40Z",
             "detailsUrl": "https://github.com/example/widgets/actions/runs/\(run)/job/1",
             "checkSuite": ["workflowRun": ["databaseId": run, "workflow": ["name": workflow]]]]
        }
        func detail(state: String, checks: [[String: Any]], reviews: [[String: Any]], openThreads: Int) -> [String: Any] {
            ["baseRef": ["compare": ["behindBy": 0]],
             "commits": ["nodes": [["commit": ["statusCheckRollup": [
                "state": state, "contexts": ["totalCount": checks.count, "nodes": checks]]]]]],
             "latestOpinionatedReviews": ["nodes": reviews],
             "reviewThreads": ["nodes": Array(repeating: ["isResolved": false], count: openThreads)]]
        }
        let state: [String: Any] = [
            "refs": ["native-panel", "switcher-width"],
            "pulls": [
                pull(139, "native-panel", title: "Native panel spacing", mergeState: "UNSTABLE", review: "REVIEW_REQUIRED"),
                pull(137, "switcher-width", title: "Switcher preview width", mergeState: "BLOCKED", review: "CHANGES_REQUESTED"),
            ],
            "details": [
                "139": detail(state: "FAILURE", checks: [
                    check("build", "build", "SUCCESS", run: 300), check("lint", "swiftformat", "FAILURE", run: 301),
                    check("test", "macos-26", "FAILURE", run: 302),
                ], reviews: [], openThreads: 0),
                "137": detail(state: "SUCCESS", checks: [check("build", "build", "SUCCESS", run: 303)],
                              reviews: [["state": "CHANGES_REQUESTED"]], openThreads: 3),
            ],
        ]
        return try JSONSerialization.data(withJSONObject: state)
    }

    private static func sendSteps(_ app: DriverApp) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let fakeGH = env["LOAM_DRIVER_FAKE_GH"] else { throw DriverFailure("LOAM_DRIVER_FAKE_GH does not name the fake gh") }
        guard let fakeClaude = env["LOAM_DRIVER_FAKE_CLAUDE"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_CLAUDE does not name the fake claude")
        }
        let rig = try PanelRig(outFolder: app.outFolder)
        let ghState = rig.root.appendingPathComponent("gh-state.json")
        try sendGitHub().write(to: ghState)
        let prompts = rig.root.appendingPathComponent("prompts.txt")
        func sent() -> String { (try? String(contentsOf: prompts, encoding: .utf8)) ?? "" }
        let bin = rig.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: fakeClaude, toPath: bin.appendingPathComponent("claude").path)

        // 1. A repo with two worktrees, each with a PR. The remote becomes a GitHub address after the worktrees exist,
        // so no git command asks the network.
        let plot = try rig.newPlot("Widgets")
        let widgets = try makeRepo(rig, named: "widgets")
        try rig.loam(["repo", "add", plot, widgets.path])
        let panel = try makeWorktree(rig, plot: plot, repo: widgets, name: "native-panel")
        let switcher = try makeWorktree(rig, plot: plot, repo: widgets, name: "switcher-width")
        try git(widgets, ["remote", "set-url", "origin", "https://github.com/example/widgets.git"])
        // Each session sets the title that Claude Code would give it, from the folder of its worktree.
        let titles = [
            URL(fileURLWithPath: panel.path).lastPathComponent: "\u{2733} Native panel spacing",
            URL(fileURLWithPath: switcher.path).lastPathComponent: "\u{2733} Switcher preview width",
        ]
        let titlesJSON = String(decoding: try JSONSerialization.data(withJSONObject: titles), as: UTF8.self)

        let client = LoamClient(binary: rig.binary, environment: rig.environment.merging(try rig.neutralPrompt()) { $1 }.merging([
            "PATH": bin.path + ":" + (env["PATH"] ?? "/usr/bin:/bin"),
            "LOAM_FAKE_CLAUDE_OUT": rig.root.appendingPathComponent("claude-invocation.json").path,
            "LOAM_FAKE_CLAUDE_HOOKS": "1",
            "LOAM_FAKE_CLAUDE_TURN": "\(Int(turnSeconds))s",
            "LOAM_FAKE_CLAUDE_PROMPTS": prompts.path,
            "LOAM_FAKE_CLAUDE_TITLES": titlesJSON,
            "LOAM_GH": fakeGH, "LOAM_FAKE_GH_STATE": ghState.path,
            "LOAM_FAKE_GH_LOG": rig.root.appendingPathComponent("gh-calls.jsonl").path,
        ]) { $1 })
        // The timers are far away, so only the launch and the popover make a refresh.
        let host = try await app.launchApp(client: client, state: rig.stateFile, terminals: true) { host in
            host.model.shipRefresh.timing.activeInterval = .seconds(3600)
            host.model.shipRefresh.timing.otherInterval = .seconds(3600)
        }
        // Room in the action bar for the toast after the pane label.
        host.window.setFrame(NSRect(x: 80, y: 80, width: 1360, height: 720), display: true)
        let model = host.model
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }
        try await app.waitUntil("the stages") {
            model.worktreeStatus(panel.id)?.stage == .checksFailed && model.worktreeStatus(switcher.id)?.stage == .changesRequested
        }
        func worktree(_ id: String) throws -> Worktree {
            try model.worktreeStatus(id)?.worktree ?? { throw DriverFailure("the list has no worktree \(id)") }()
        }
        func terminal(_ pane: PaneID) throws -> TerminalSurfaceView {
            guard let view = host.paneView(pane) as? TerminalSurfaceView else { throw DriverFailure("pane \(pane) has no terminal") }
            return view
        }
        func hasTheKeys(_ pane: PaneID) -> Bool { host.window.firstResponder === host.paneView(pane) }
        func screen(_ pane: PaneID) -> String { ((try? terminal(pane)).map { app.lines($0).joined(separator: "\n") }) ?? "" }
        /// True when the last line with text is the prompt of the fake `claude`.
        func atPrompt(_ pane: PaneID) -> Bool { ((try? terminal(pane)).flatMap { app.lines($0).last { !$0.isEmpty } }) == ">" }
        func primary() -> (title: String, pane: String)? {
            AccessibilityProbe.shared.node("pr-popover-primary").map { ($0.description, $0.value) }
        }
        /// Opens the popover of native-panel from the chip of the action bar. While a toast shows in place of the chip,
        /// the popover opens as a key opens it.
        func openPopover() async throws {
            if app.exists("action-bar-pr-chip") { try app.click("action-bar-pr-chip") } else { model.openPullRequest(panel.id) }
            try await app.waitUntil("the popover opens") { app.exists("pr-popover-primary") && model.prPopover.worktreeID == panel.id }
            try await app.waitUntil("the popover is done") { !model.prPopover.isRefreshing }
        }
        func closePopover() async throws {
            app.press(.escape)
            try await app.waitUntil("Escape closes the popover") { !app.exists("pr-popover") && !model.prPopover.isOpen }
        }
        /// The shot waits for the popover and the toast to finish their animations.
        func settledShot(_ name: String) async throws {
            try await Task.sleep(for: .seconds(LoamTheme.durationBase * 2))
            app.screenshot(name)
        }

        // 2. A session in native-panel. It is idle, so the popover offers to type the failures into it.
        model.openWorktreePane(try worktree(panel.id))
        let session = try model.workspace.focusedPane ?? { throw DriverFailure("no session pane") }()
        try await app.waitUntil("the session is idle") { model.workspace.state(of: session) == .idle }
        try await app.waitUntil("the session shows its prompt") { atPrompt(session) && hasTheKeys(session) }
        try await app.waitUntil("the session sets its title") { model.terminalTitles[session] == "\u{2733} Native panel spacing" }
        try await app.waitUntil("the chip") { app.exists("action-bar-pr-chip") }
        try await openPopover()
        try expectSend(primary()?.title == "Send failures to session" && primary()?.pane == "\u{2733} Native panel spacing",
                       "the primary button reads \(String(describing: primary()))")
        try expectSend(app.text(of: "pr-popover-send-note") == "Loam types the prompt into the session. You press Return.",
                       "the footnote reads \(app.text(of: "pr-popover-send-note") ?? "nothing")")
        try await settledShot("send-popover-failed")

        // 3. Return in the popover types the prompt into the input and gives the session the keys. You hold Return
        // a little: its repeats reach the terminal, which drops them until a new key down. Nothing is sent: the fake
        // `claude` got no prompt.
        try await app.waitUntil("the popover has the keys") { !hasTheKeys(session) }
        await app.sleep(0.3)
        app.keyDown(.returnKey)
        try await app.waitUntil("the session has the keys") { hasTheKeys(session) }
        for _ in 0..<3 { app.keyDown(.returnKey, isARepeat: true) }
        app.keyUp(.returnKey)
        try await app.waitUntil("the popover closes") { !model.prPopover.isOpen }
        try await app.waitUntil("the prompt is in the input") { screen(session).contains("Checks failed on #139") }
        try await app.waitUntil("the toast") {
            app.text(of: "action-bar-toast")?.contains("Loam typed the failures into \u{2733} Native panel spacing. Press Return to send.") == true
        }
        try await settledShot("send-prompt-typed")
        await app.sleep(1)
        try expectSend(sent().isEmpty && model.workspace.state(of: session) == .idle, "the prompt went to the session: \(sent())")

        // 4. Return sends it. During the turn the session is busy: the button copies the prompt.
        app.press(.returnKey)
        try await app.waitUntil("the session got the prompt") { sent() == failuresPrompt + "\n" }
        try await app.waitUntil("the turn runs") { model.workspace.state(of: session) == .working }
        // The toast of the typed prompt fades first, so the shot of the busy session does not show it.
        try await app.waitUntil("the toast fades", timeout: ActionBarModel.toastSeconds + 3) { !app.exists("action-bar-toast") }
        try await openPopover()
        try expectSend(primary()?.title == "Copy prompt" && primary()?.pane.isEmpty == true,
                       "the busy button reads \(String(describing: primary()))")
        try expectSend(app.text(of: "pr-popover-send-note") == "The session is busy. Copy the prompt and send it when the turn ends.",
                       "the busy footnote reads \(app.text(of: "pr-popover-send-note") ?? "nothing")")
        try await settledShot("send-popover-busy")
        try app.click("pr-popover-primary")
        try await app.waitUntil("the copy note") { app.text(of: "pr-popover-note") == "Copied the prompt." }
        try expectSend(app.runtime.pasteboard.string(forType: .string) == failuresPrompt,
                       "the pasteboard holds \(app.runtime.pasteboard.string(forType: .string) ?? "nothing")")
        try expectSend(model.workspace.state(of: session) == .working, "the turn ended before the busy steps were done")
        try await closePopover()

        // 5. During the turn, you paste the prompt with Edit > Paste, dictate a word, and press ⌘⌫. Each changes the
        // input, so each reaches the input hook of the terminal. ⌘⌫ clears the line, so the later shots do not show it.
        // ⌘↑ moves the view, not the input, so it does not count. The driver app is not frontmost, so its window
        // is not key and ⌘V finds no target. The Paste item sends its action to the terminal, as in the key window.
        try await app.waitUntil("the session has the keys in the turn") { hasTheKeys(session) }
        let afterSubmit = model.workspace.session(of: session)
        try expectSend(afterSubmit?.typedSinceSubmit == false && afterSubmit?.loamPrompt == nil, "the submit did not empty the input")
        let view = try terminal(session)
        let hook = view.onInput
        let inputs = InputCount()
        view.onInput = { kind in inputs.value += 1; hook?(kind) }
        let editItems = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
        guard let paste = editItems.first(where: { $0.action == #selector(NSText.paste(_:)) }), let action = paste.action else {
            throw DriverFailure("the menu has no Paste item")
        }
        NSApp.sendAction(action, to: host.window.firstResponder, from: paste)
        try await app.waitUntil("the paste counts") { inputs.value == 1 && model.workspace.session(of: session)?.typedSinceSubmit == true }
        view.insertText("\u{E9}", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await app.waitUntil("the dictated word counts") { inputs.value == 2 }
        app.press(.delete, flags: .command)
        try await app.waitUntil("command-delete counts") { inputs.value == 3 }
        app.press(.up, flags: .command)
        await app.sleep(0.3)
        try expectSend(inputs.value == 3, "command-up counted as input")
        view.onInput = hook
        try expectSend(model.workspace.state(of: session) == .working, "the turn ended before the keys of the turn")

        // 6. Claude Code keeps the text that you typed during the turn, so after the Stop the input can still hold
        // your text. The button copies again, and the ⌘J row opens the popover, so you see why.
        try await app.waitUntil("the turn ends", timeout: turnSeconds + 5) { model.workspace.state(of: session) == .idle }
        try expectSend(model.workspace.session(of: session)?.typedSinceSubmit == true, "the Stop emptied the input")
        try await openPopover()
        try expectSend(primary()?.title == "Copy prompt", "the button after a key reads \(String(describing: primary()))")
        try expectSend(app.text(of: "pr-popover-send-note") == "You have typed in this session. Loam does not type over your text.",
                       "the typed footnote reads \(app.text(of: "pr-popover-send-note") ?? "nothing")")
        try await closePopover()
        try await app.waitUntil("the session has the keys after the popover") { hasTheKeys(session) }
        app.press(letter: "j", flags: .command)
        try await app.waitUntil("the menu has Send failures to session") { app.exists("actions-row-Send failures to session") }
        try await app.waitUntil("the search field has the keys") { host.window.firstResponder is NSTextView }
        try app.type("send")
        app.press(.returnKey)
        try await app.waitUntil("the row opens the popover") { !app.exists("actions-menu") && app.exists("pr-popover-primary") }
        try expectSend(primary()?.title == "Copy prompt" && model.prPopover.worktreeID == panel.id, "the row did not open the Copy prompt state")
        try expectSend(sent() == failuresPrompt + "\n", "the menu sent a prompt: \(sent())")
        try await closePopover()

        // 7. switcher-width has no session. The button starts one, and types the review prompt after its SessionStart.
        try expectSend(model.openPullRequest(switcher.id), "the popover of switcher-width did not open")
        try await app.waitUntil("the popover of switcher-width") { app.exists("pr-popover-primary") && !model.prPopover.isRefreshing }
        try expectSend(primary()?.title == "Start session with prompt", "the button without a session reads \(String(describing: primary()))")
        try expectSend(app.text(of: "pr-popover-send-note")
                       == "No session runs in this worktree. Loam starts one and types the review prompt. You press Return.",
                       "the start footnote reads \(app.text(of: "pr-popover-send-note") ?? "nothing")")
        try await settledShot("send-popover-start")
        try app.click("pr-popover-primary")
        try await app.waitUntil("a session opens in switcher-width") { model.focusedWorktree?.id == switcher.id && !model.prPopover.isOpen }
        let started = try model.workspace.focusedPane ?? { throw DriverFailure("no new pane") }()
        try expectSend(started != session && model.workspace.spec(of: started)?.kind == .session, "the new pane is not a session")
        try await app.waitUntil("the review prompt is in the input") { screen(started).contains("PR #137 has changes requested") }
        try await app.waitUntil("the review toast") {
            app.text(of: "action-bar-toast")?.contains("Loam typed the review into the new session. Press Return to send.") == true
        }
        let typed = model.workspace.session(of: started)
        try expectSend(typed?.started == true && typed?.loamPrompt == reviewPrompt, "the pane does not hold the review prompt after its SessionStart")
        await app.sleep(1)
        try expectSend(sent() == failuresPrompt + "\n", "the new session sent a prompt: \(sent())")

        // 8. You add a word to the prompt and press Return. Claude Code takes the input, so it is empty again.
        try await app.waitUntil("the new session has the keys") { hasTheKeys(started) }
        try app.type(" now")
        try await app.waitUntil("the word counts") { model.workspace.session(of: started)?.typedSinceReturn == true }
        app.press(.returnKey)
        try await app.waitUntil("the session got the review prompt") { sent() == failuresPrompt + "\n" + reviewPrompt + " now\n" }
        try await app.waitUntil("the submit empties the input") {
            let input = model.workspace.session(of: started)
            return input?.typedSinceSubmit == false && input?.loamPrompt == nil
        }
        Log.line("RESULT prompts sent: \(sent().split(separator: "\n").count)")
    }
}
