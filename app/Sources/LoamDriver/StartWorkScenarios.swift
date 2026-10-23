import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 115: Start work from a link. Start work… on a Linear issue link opens the New worktree
/// sheet with the branch, the goal and the link filled in. The sheet checks the branch as you type, Start session makes
/// the worktree and starts a seeded session in it, and the plus of the Worktrees section opens the sheet with no link. The
/// session is the core's fake `claude` (`LOAM_DRIVER_FAKE_CLAUDE`), which writes its arguments and its folder to a file.
/// The Linear issue is made up, and no command goes to Linear or GitHub: the core does not read the issue. It uses a temp
/// `LOAM_HOME` and never touches `~/.loam` or a real repo.
@MainActor
extension Scenarios {
    private static func expectStart(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func startWork(_ app: DriverApp) async throws {
        do { try await startWorkSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private struct StartInvocation: Decodable {
        var args: [String]
        var cwd: String?
    }

    private static let issueLabel = "ENG-482 Link kinds for Figma"
    private static let issueURL = "https://linear.app/example/issue/ENG-482/link-kinds-for-figma"
    private static let issueBranch = "eng-482-link-kinds-for-figma"

    /// The menu window that shows over the driver window while a menu tracks the mouse, or nil.
    private static func menuWindow(of app: DriverApp) -> NSWindow? {
        NSApp.windows.first { $0 !== app.window && $0.isVisible && $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue }
    }

    /// The context menu of the panel row `id`, as SwiftUI builds it for a right click in the middle of the row, and the
    /// view and the point to show it at. The frame of the row has its origin at the top left of the main screen, and the
    /// window point at the bottom left.
    private static func rowMenu(of app: DriverApp, _ id: String) throws -> (menu: NSMenu, view: NSView, point: NSPoint) {
        guard let frame = AccessibilityProbe.shared.node(id)?.frame, let top = NSScreen.screens.first?.frame.maxY,
              let content = app.window.contentView
        else { throw DriverFailure("no row \(id) on screen") }
        let point = app.window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: top - frame.midY))
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { throw DriverFailure("no mouse event") }
        var view = content.hitTest(content.convert(point, from: nil))
        while let current = view {
            if let menu = current.menu(for: event), !menu.items.isEmpty { return (menu, current, current.convert(point, from: nil)) }
            view = current.superview
        }
        throw DriverFailure("no view under \(id) has a context menu")
    }

    private static func startWorkSteps(_ app: DriverApp) async throws {
        guard let fakeClaude = ProcessInfo.processInfo.environment["LOAM_DRIVER_FAKE_CLAUDE"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_CLAUDE does not name the fake claude")
        }
        let rig = try PanelRig(outFolder: app.outFolder)
        let fm = FileManager.default
        let bin = rig.root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.copyItem(atPath: fakeClaude, toPath: bin.appendingPathComponent("claude").path)
        let invocationFile = rig.root.appendingPathComponent("claude-invocation.json")
        func invocation() -> StartInvocation? {
            (try? Data(contentsOf: invocationFile)).flatMap { try? JSONDecoder().decode(StartInvocation.self, from: $0) }
        }
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        /// What the element reads, for the message of a failed check.
        func reads(_ id: String) -> String { app.text(of: id) ?? "nothing" }

        // 1. A plot with a repo that has a branch named fix-login, a Linear issue as a link, and a page that is no issue.
        let plot = try rig.newPlot("Widgets")
        let widgets = try makeRepo(rig, named: "widgets")
        try rig.loam(["repo", "add", plot, widgets.path])
        try git(widgets, ["branch", "fix-login"])
        try rig.loam(["link", "add", plot, issueLabel, issueURL])
        try rig.loam(["link", "add", plot, "Launch plan", "https://www.notion.so/example/Launch-plan-0123456789abcdef0123456789abcdef"])
        let links = try rig.show(plot)["links"] as? [[String: Any]] ?? []
        func linkID(_ label: String) throws -> String {
            guard let id = links.first(where: { $0["label"] as? String == label })?["id"] as? String else {
                throw DriverFailure("the plot has no link \(label)")
            }
            return id
        }
        let issueRow = "panel-link-row-\(try linkID(issueLabel))"
        let pageRow = "panel-link-row-\(try linkID("Launch plan"))"

        let environment = rig.environment.merging(try rig.neutralPrompt()) { $1 }.merging([
            "PATH": bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
            "LOAM_FAKE_CLAUDE_OUT": invocationFile.path,
            "LOAM_FAKE_CLAUDE_HOOKS": "1",
            "LOAM_FAKE_CLAUDE_TURN": "1s",
        ]) { $1 }
        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        host.window.setFrame(NSRect(x: 80, y: 80, width: 1360, height: 780), display: true)
        let model = host.model
        let sheet = model.newWorktreeSheet
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }
        try await app.openPanel(host)
        try await app.waitUntil("the link rows") { app.exists(issueRow) && app.exists(pageRow) }
        /// The shot waits for the sheet and the toast to finish their animations.
        func settledShot(_ name: String, menu: NSWindow? = nil) async throws {
            try await Task.sleep(for: .seconds(LoamTheme.durationSlow * 2))
            app.screenshot(name, menu: menu)
        }

        // 2. Start work… is on the menu of an issue link, at the top over a divider. A link that is no issue has none.
        try expectStart(!AccessibilityProbe.shared.performAction(pageRow, named: "Start work\u{2026}"),
                        "a link that is no issue offers Start work\u{2026}")
        try expectStart(!sheet.isOpen, "the sheet opened for a link that is no issue")
        let shown = try rowMenu(of: app, issueRow)
        let titles = shown.menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        Log.line("RESULT link menu: \(titles.joined(separator: " | "))")
        try expectStart(titles.first == "Start work\u{2026}" && titles.dropFirst().first == "-",
                        "the menu starts with \(titles.prefix(2)), not Start work\u{2026} over a divider")
        // The shot of the open menu needs the app to be active, and a menu takes the keyboard. So only a run in the foreground
        // takes it (LOAM_DRIVER_FOREGROUND=1). Then the app you used before is active again.
        if Driver.foreground {
            // A menu tracks the mouse in a loop of its own, where no task runs. A timer of the common modes does run there. It
            // takes the shot of the open menu and closes it, and the pop-up returns.
            let previous = NSWorkspace.shared.frontmostApplication
            NSApp.activate()
            app.window.makeKeyAndOrderFront(nil)
            try await app.waitUntil("the app is active") { NSApp.isActive }
            let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let window = menuWindow(of: app)
                    Log.line("RESULT menu window: \(window.map { "\(Swift.type(of: $0)) \($0.frame)" } ?? "none")")
                    app.screenshot("start-work-link-menu", menu: window)
                    shown.menu.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            shown.menu.popUp(positioning: nil, at: shown.point, in: shown.view)
            if let previous, previous != NSRunningApplication.current { previous.activate() }
        }

        // 3. Start work… fills the sheet from the link: the branch and the goal from the label, the link, and the base.
        try app.perform("Start work\u{2026}", on: issueRow)
        try await app.waitUntil("the sheet opens") { sheet.isOpen && app.exists("new-worktree-sheet") }
        try await app.waitUntil("the branch is checked") { sheet.branchState == .new }
        try expectStart(sheet.branch == issueBranch, "the branch reads \(sheet.branch)")
        try expectStart(sheet.goal == "Link kinds for Figma", "the goal reads \(sheet.goal)")
        try expectStart(sheet.defaultBase == "origin/main", "the default base reads \(sheet.defaultBase)")
        // The popup shows the base of the answer after the next render. Under load, that render can come after this line.
        try await app.waitUntil("the base popup reads origin/main", timeout: 3) { app.text(of: "new-worktree-base") == "origin/main" }
        try expectStart(app.text(of: "new-worktree-branch") == issueBranch, "the branch field reads \(reads("new-worktree-branch"))")
        try expectStart(app.text(of: "new-worktree-goal") == "Link kinds for Figma", "the goal field reads \(reads("new-worktree-goal"))")
        try expectStart(app.text(of: "new-worktree-repo") == "widgets", "the repo reads \(reads("new-worktree-repo"))")
        try expectStart(app.text(of: "new-worktree-link") == issueLabel, "the link reads \(reads("new-worktree-link"))")
        let card = app.text(of: "new-worktree-link-card") ?? ""
        try expectStart(card.contains(issueLabel) && card.contains("Linear connector"), "the link card reads \(card)")
        try expectStart(app.text(of: "new-worktree-branch-note") == "From the issue key and the link label.",
                        "the branch note reads \(reads("new-worktree-branch-note"))")
        try expectStart(AccessibilityProbe.shared.isEnabled("new-worktree-start"), "Start session is off for a good branch")
        try await settledShot("start-work-sheet")

        // "What the seed adds" shows the line that the seed of the plot gets, with the key and the base.
        try app.click("new-worktree-seed")
        try await app.waitUntil("the seed line shows") { app.exists("new-worktree-seed-line") }
        let seedLine = (sheet.seedLine ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try expectStart(seedLine.hasPrefix("- ") && seedLine.hasSuffix(": Link kinds for Figma (ENG-482, from origin/main)"),
                        "the seed line reads \(seedLine)")
        try expectStart(app.text(of: "new-worktree-seed-line") == seedLine, "the sheet shows \(reads("new-worktree-seed-line"))")
        try app.click("new-worktree-seed")
        try await app.waitUntil("the seed line hides") { !app.exists("new-worktree-seed-line") }

        // 4. A branch that exists: the note says that Loam uses it, the base is off, and Start session stays on. A name that
        // git refuses shows the message of the core and turns Start session off.
        try app.fill("new-worktree-branch", with: "fix-login")
        try await app.waitUntil("the branch exists") { sheet.branchState == .exists }
        try expectStart(app.text(of: "new-worktree-branch-note") == "A branch with this name exists. Loam uses it as it is.",
                        "the note reads \(reads("new-worktree-branch-note"))")
        try expectStart(!AccessibilityProbe.shared.isEnabled("new-worktree-base"), "the base is on for a branch that exists")
        try expectStart(AccessibilityProbe.shared.isEnabled("new-worktree-start"), "Start session is off for a branch that exists")
        try await settledShot("start-work-branch-exists")
        try app.fill("new-worktree-branch", with: "bad name")
        try await app.waitUntil("the name is refused") {
            if case .invalid = sheet.branchState { return true } else { return false }
        }
        Log.line("RESULT bad name note: \(reads("new-worktree-branch-note"))")
        try expectStart(app.text(of: "new-worktree-branch-note")?.isEmpty == false, "a bad name has no note")
        try expectStart(!AccessibilityProbe.shared.isEnabled("new-worktree-start"), "Start session is on for a bad name")
        try app.fill("new-worktree-branch", with: issueBranch)
        try await app.waitUntil("the branch is good again") { sheet.branchState == .new }

        // 5. Start session makes the worktree with the goal and the link, and starts a seeded session in it.
        try app.click("new-worktree-start")
        try await app.waitUntil("the sheet closes", timeout: 20) { !sheet.isOpen }
        try await app.waitUntil("the worktree is listed") { model.worktrees[plot]?.contains { $0.worktree.branch == issueBranch } == true }
        guard let made = model.worktrees[plot]?.first(where: { $0.worktree.branch == issueBranch })?.worktree else {
            throw DriverFailure("no worktree \(issueBranch)")
        }
        try expectStart(made.goal == "Link kinds for Figma", "the worktree goal reads \(made.goal ?? "nothing")")
        try expectStart(made.link?.key == "ENG-482" && made.link?.target == issueURL, "the worktree link reads \(String(describing: made.link))")
        let pane = try model.workspace.selectedTab(of: .plot(plot))?.focused ?? { throw DriverFailure("no pane") }()
        let spec = model.workspace.spec(of: pane)
        try expectStart(spec?.kind == .session && spec?.worktree?.id == made.id, "the pane is not a session in the worktree")
        try await app.waitUntil("claude started in the worktree") { invocation()?.cwd.map(resolved) == resolved(made.path) }
        let plotFolder = rig.loamHome.appendingPathComponent("plots/\(plot)").path
        try expectStart(invocation()?.args.contains { resolved($0) == resolved(plotFolder) } == true,
                        "claude got no --add-dir of the plot folder: \(invocation()?.args ?? [])")
        let seed = try String(contentsOf: rig.loamHome.appendingPathComponent("plots/\(plot)/CLAUDE.md"), encoding: .utf8)
        try expectStart(seed.contains(seedLine), "the seed of the plot has no line \(seedLine)")

        // 6. The issue key shows in line 2 of the Worktrees row. The sidebar row shows it only when it fits after the whole
        // name. At the default width it does not fit after this name, so the row shows the name and no key. The label of the
        // row has the key in both cases, and so has the tooltip (`SidebarModel.WorktreeRow.tooltip`).
        try await app.waitUntil("the sidebar row") { app.exists("worktree-\(made.id)") }
        try expectStart(app.text(of: "worktree-\(made.id)") == "\(issueBranch), ENG-482",
                        "the sidebar row reads \(app.text(of: "worktree-\(made.id)") ?? "nothing")")
        try await app.waitUntil("the Worktrees row") { app.exists("panel-worktree-\(made.id)") }
        try expectStart(app.text(of: "panel-worktree-\(made.id)")?.contains("ENG-482") == true,
                        "the Worktrees row reads \(app.text(of: "panel-worktree-\(made.id)") ?? "nothing")")
        try await settledShot("start-work-rows")

        // The goal of a worktree with no PR is edited in the PR popover. Escape in a composition is for the input method.
        // The edit stays. Escape after it ends the edit, and the next Escape closes the popover.
        try expectStart(model.openPullRequest(made.id), "the PR popover did not open for the new worktree")
        try await app.waitUntil("the popover opens") { app.exists("pr-popover") && app.exists("pr-popover-goal") }
        try app.click("pr-popover-goal")
        try await app.waitUntil("the goal field shows") { app.exists("pr-popover-goal-field") }
        _ = AccessibilityProbe.shared.focus("pr-popover-goal-field")
        try await app.waitUntil("the goal field edits") { (app.window.firstResponder as? NSTextView)?.isFieldEditor == true }
        guard let goalEditor = app.window.firstResponder as? NSTextView else { throw DriverFailure("the popover goal field has no editor") }
        goalEditor.setMarkedText("\u{306B}\u{307B}\u{3093}", selectedRange: NSRange(location: 3, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        try expectStart(goalEditor.hasMarkedText(), "the popover editor took no marked text")
        app.press(.escape)
        await app.sleep(0.5)
        try expectStart(model.prPopover.isOpen && model.prPopover.goalDraft != nil, "Escape in a composition ended the goal edit")
        goalEditor.unmarkText()
        app.press(.escape)
        try await app.waitUntil("Escape ends the goal edit") { model.prPopover.goalDraft == nil }
        try expectStart(model.prPopover.isOpen, "Escape ended the goal edit and closed the popover")

        // A save that finds a newer goal shows it in the field. The field has the keys again, so Return saves it. The field is
        // off while the save runs, and a field that is off loses the keys.
        try await app.waitUntil("the goal row shows again") { app.exists("pr-popover-goal") && !app.exists("pr-popover-goal-field") }
        try app.click("pr-popover-goal")
        try await app.waitUntil("the goal field shows again") { app.exists("pr-popover-goal-field") }
        _ = AccessibilityProbe.shared.focus("pr-popover-goal-field")
        try await app.waitUntil("the goal field edits again") { (app.window.firstResponder as? NSTextView)?.isFieldEditor == true }
        let newerGoal = "Link kinds for Figma and Miro"
        try rig.loam(["worktree", "edit", plot, made.id, "--goal", newerGoal])
        app.press(.returnKey)
        try await app.waitUntil("the save shows the newer goal") {
            model.prPopover.goalDraft == newerGoal && model.prPopover.goalProblem == "The goal changed meanwhile. Loam shows the new goal."
        }
        try await app.waitUntil("the goal field has the keys after the save", timeout: 3) {
            (app.window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        app.press(.returnKey)
        try await app.waitUntil("Return saves the goal") { model.prPopover.goalDraft == nil }
        try expectStart(model.prPopover.isOpen, "Return in the goal field closed the popover")

        app.press(.escape)
        try await app.waitUntil("Escape closes the popover") { !model.prPopover.isOpen && !app.exists("pr-popover") }

        // 7. The plus of the Worktrees section opens the sheet with no link: nothing is filled, and Start session is off.
        // The sheet gives Branch the keys as it opens, for a short time. A Tab at that time moves the keys off Branch, and
        // they stay where the Tab put them.
        /// The label of the text field that has the keys, or nil.
        func fieldWithTheKeys() -> String? {
            guard let editor = app.window.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
            return (editor.delegate as? NSView)?.accessibilityLabel()
        }
        try app.click("panel-add-worktree")
        let clicked = Date()
        while fieldWithTheKeys() != "Branch" {
            if Date().timeIntervalSince(clicked) > 5 { throw DriverFailure("Branch did not get the keys when the sheet opened") }
            try await Task.sleep(for: .milliseconds(5))
        }
        Log.line(String(format: "RESULT Branch has the keys %.3f s after the click", Date().timeIntervalSince(clicked)))
        app.press(.tab)
        // The sheet tries for about 130 ms. For a second, the keys never go back to Branch.
        let tabbed = Date()
        while Date().timeIntervalSince(tabbed) < 1 {
            try expectStart(fieldWithTheKeys() != "Branch", "a Tab as the sheet opened went back to Branch")
            try await Task.sleep(for: .milliseconds(10))
        }
        try await app.waitUntil("the empty sheet opens") { sheet.isOpen && sheet.phase == .ready && app.exists("new-worktree-sheet") }
        try expectStart(sheet.startLink == nil && sheet.branch.isEmpty && sheet.goal.isEmpty, "the sheet from the plus is not empty")
        try expectStart(!app.exists("new-worktree-link-card"), "the sheet from the plus shows a link card")
        try expectStart(app.text(of: "new-worktree-link") == NewWorktreeContent.noLink, "the link reads \(reads("new-worktree-link"))")
        try expectStart(app.text(of: "new-worktree-repo") == "widgets", "the repo reads \(reads("new-worktree-repo"))")
        try expectStart(!AccessibilityProbe.shared.isEnabled("new-worktree-start"), "Start session is on with no branch")
        try expectStart(app.text(of: "new-worktree-goal-note") == NewWorktreeContent.goalHint,
                        "the goal note reads \(reads("new-worktree-goal-note"))")

        // A goal over 20 words still saves. The note warns.
        let long = (1...24).map { "word\($0)" }.joined(separator: " ")
        try app.fill("new-worktree-goal", with: long)
        try await app.waitUntil("the goal warns") {
            app.text(of: "new-worktree-goal-note") == "The goal has 24 words. The soft limit is 20 words."
        }
        // Escape in the middle of a composition (marked text, as an input method makes it) is for the input method. The sheet stays.
        _ = AccessibilityProbe.shared.focus("new-worktree-goal")
        try await app.waitUntil("the goal field edits") { (app.window.firstResponder as? NSTextView)?.isFieldEditor == true }
        guard let editor = app.window.firstResponder as? NSTextView else { throw DriverFailure("the goal field has no editor") }
        editor.setMarkedText("\u{306B}\u{307B}\u{3093}", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        try expectStart(editor.hasMarkedText(), "the editor took no marked text")
        app.press(.escape)
        await app.sleep(0.5)
        try expectStart(sheet.isOpen, "Escape in a composition closed the sheet")
        editor.unmarkText()
        app.press(.escape)
        try await app.waitUntil("Escape closes the sheet") { !sheet.isOpen && !app.exists("new-worktree-sheet") }

        // 8. In the switcher, ⌘Return on the issue link runs Start work… and nothing else: the link does not open. Return on
        // the same link opens it and opens no sheet. The keys go through the window, as a key press does.
        func selectIssueInSwitcher() async throws {
            try app.pressMenuKey("p", flags: .command)
            try await app.waitUntil("the switcher shows", timeout: 5) { app.exists("switcher-field") }
            try app.fill("switcher-field", with: "ENG-482")
            func issueRow() -> Int? { model.switcher.results.firstIndex { $0.item.kind == .link && $0.item.title == issueLabel } }
            try await app.waitUntil("the issue link row", timeout: 10) { issueRow() != nil }
            model.switcher.selection = issueRow() ?? 0
        }
        try await selectIssueInSwitcher()
        let opened = rig.openCalls.count
        app.press(.returnKey, flags: .command)
        try await app.waitUntil("⌘Return opens the sheet from the link", timeout: 5) {
            sheet.isOpen && sheet.startLink?.label == issueLabel && !model.switcher.isOpen
        }
        await app.sleep(2)
        try expectStart(rig.openCalls.count == opened, "⌘Return also opened the link: \(rig.openCalls.suffix(2))")
        app.press(.escape)
        try await app.waitUntil("Escape closes the sheet from the switcher") { !sheet.isOpen }
        try await selectIssueInSwitcher()
        app.press(.returnKey)
        try await app.waitUntil("Return opens the link", timeout: 10) { rig.openCalls.dropFirst(opened).contains { $0.contains(issueURL) } }
        try expectStart(!sheet.isOpen && !model.switcher.isOpen, "Return on the issue link opened the sheet")
        // One open for the two keys: a late open from ⌘Return would make two.
        await app.sleep(1)
        let issueOpens = rig.openCalls.dropFirst(opened).filter { $0.contains(issueURL) }.count
        try expectStart(issueOpens == 1, "the issue link opened \(issueOpens) times for one Return and one ⌘Return")
    }
}
