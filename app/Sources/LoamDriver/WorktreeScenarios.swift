import AppKit
import LoamKit
import LoamTerminal

/// Driver scenario for ticket 41: worktrees in the app. It uses a temp `LOAM_HOME`, a temp git repo
/// with a temp bare repo as `origin`, and the core's fake `claude` in hook mode. It never touches
/// `~/.loam` or a real repo. `LOAM_DRIVER_FAKE_CLAUDE` names the fake binary.
@MainActor
extension Scenarios {
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DriverFailure(message()) }
    }

    static func worktrees(_ app: DriverApp) async throws {
        do { try await worktreeSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    private struct Invocation: Decodable {
        var args: [String]
        var cwd: String?
    }

    /// Runs git in a folder with no global config, so the host's signing and hooks do not matter. It returns the
    /// output, trimmed.
    @discardableResult
    static func git(_ folder: URL, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Driver", "-c", "user.email=driver@example.com",
                             "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
        process.currentDirectoryURL = folder
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": folder.path,
                               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw DriverFailure("git \(args.joined(separator: " ")) failed in \(folder.path)") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One MCP call as Claude would make it. The setup command that it sets is not approved.
    private static func mcpCall(_ app: DriverApp, _ rig: PanelRig, _ tool: String, _ arguments: [String: Any]) async throws {
        try await rig.mcp([(tool, arguments)], session: "cccccccc-1111-4222-8333-444444444444", app: app)
    }

    private static func worktreeSteps(_ app: DriverApp) async throws {
        let rig = try PanelRig(outFolder: app.outFolder)
        guard let fake = ProcessInfo.processInfo.environment["LOAM_DRIVER_FAKE_CLAUDE"] else {
            throw DriverFailure("LOAM_DRIVER_FAKE_CLAUDE does not name the fake claude")
        }
        let fm = FileManager.default
        let bin = rig.root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.copyItem(atPath: fake, toPath: bin.appendingPathComponent("claude").path)
        let invocationFile = rig.root.appendingPathComponent("claude-invocation.json")
        func invocation() -> Invocation? {
            (try? Data(contentsOf: invocationFile)).flatMap { try? JSONDecoder().decode(Invocation.self, from: $0) }
        }

        // A repo with a pushed commit, so the new branch starts from origin/main.
        let origin = rig.root.appendingPathComponent("origin.git")
        let repo = rig.root.appendingPathComponent("web")
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

        let plot = try rig.newPlot("Worktree plot")
        try rig.loam(["repo", "add", plot, repo.path])
        let repoID = (try rig.show(plot)["repos"] as? [[String: Any]])?.first?["id"] as? String ?? ""
        try check(!repoID.isEmpty, "the plot has no repo")
        // A setup command that Claude sets is new, so the pane asks before it runs.
        try await mcpCall(app, rig, "update_repo", ["plot": plot, "repo_id": repoID, "setup": "echo ran > setup-marker"])

        let environment = rig.environment.merging(try rig.neutralPrompt()) { $1 }.merging([
            "PATH": bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
            "LOAM_FAKE_CLAUDE_OUT": invocationFile.path,
            "LOAM_FAKE_CLAUDE_HOOKS": "1",
            "LOAM_FAKE_CLAUDE_TURN": "1s",
        ]) { $1 }
        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        let model = host.model
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }
        func surface(_ pane: PaneID) throws -> TerminalSurfaceView {
            guard let view = host.paneView(pane) as? TerminalSurfaceView else { throw DriverFailure("pane \(pane) has no terminal") }
            return view
        }

        // 1. A new worktree opens a seeded pane in it. The sidebar lists it under the plot. The New worktree sheet asks for
        // the branch (ticket 115), and Start session makes the worktree.
        let sheet = model.newWorktreeSheet
        model.openNewWorktree(plot: plot)
        try await app.waitUntil("the New worktree sheet") { sheet.isOpen && sheet.phase == .ready && app.exists("new-worktree-branch") }
        try app.fill("new-worktree-branch", with: "fix-login")
        try await app.waitUntil("the branch is good") { sheet.branchState == .new }
        try app.click("new-worktree-start")
        try await app.waitUntil("the sheet closes") { !sheet.isOpen }
        guard let made = model.worktrees[plot]?.first(where: { $0.worktree.branch == "fix-login" })?.worktree else {
            throw DriverFailure("no worktree: \(model.lastError ?? "no error")")
        }
        Log.line("RESULT worktree: \(made.path) branch \(made.branch)")
        try check(fm.fileExists(atPath: made.path + "/README.md"), "the worktree folder has no checkout")
        let pane = try model.workspace.selectedTab(of: .plot(plot))?.focused ?? { throw DriverFailure("no pane") }()
        let spec = model.workspace.spec(of: pane)
        try check(spec?.kind == .session && spec?.worktree?.id == made.id, "the pane is not a session in the worktree")
        try check(spec?.command?.contains("--worktree \(made.id)") == true, "the command has no --worktree: \(spec?.command ?? "none")")
        try await app.waitUntil("the sidebar row") { app.exists("worktree-\(made.id)") }
        try check(app.text(of: "worktree-\(made.id)")?.contains("fix-login") == true,
                  "the sidebar row shows \(app.text(of: "worktree-\(made.id)") ?? "nothing")")

        // 2. Ticket 71: the sidebar shows the pane under its worktree row. Ticket 92: the worktree row
        // sits under the main checkout row of its repo. The tab holds one pane, so the pane has no header (the branch shows in the sidebar).
        try await app.waitUntil("the pane row") { app.exists("pane-row-\(pane.uuidString)") }
        try check(app.treeParent(of: "pane-row-\(pane.uuidString)") == "worktree-\(made.id)",
                  "the pane row sits under \(app.treeParent(of: "pane-row-\(pane.uuidString)") ?? "nothing")")
        try check(app.treeParent(of: "worktree-\(made.id)") == "main-checkout-\(plot)",
                  "the worktree row sits under \(app.treeParent(of: "worktree-\(made.id)") ?? "nothing")")
        try check(!app.exists("pane-branch-\(pane.uuidString)"), "the pane alone in its tab has a header")

        // 3. The setup command is new, so the pane asks. A pane is a terminal, so the question shows there.
        let view = try surface(pane)
        try await app.waitUntil("the setup question") { view.screenText().contains("Run it? [y/N]") }
        try check(view.screenText().contains("echo ran > setup-marker"), "the question does not show the command")
        app.screenshot("worktree-setup-question")
        try app.type("y")
        app.press(.returnKey)
        try await app.waitUntil("the session started in the worktree") {
            invocation()?.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ==
                URL(fileURLWithPath: made.path).resolvingSymlinksInPath().path
        }
        try check(fm.fileExists(atPath: made.path + "/setup-marker"), "the setup command did not run in the worktree")
        try await app.waitUntil("SessionStart") { model.workspace.session(of: pane)?.started == true }
        app.screenshot("worktree-pane")

        // 4. Removal is refused while the pane is open, with and without force.
        let plan = await model.planRemoval(of: made.id)
        try check(plan == .refusedOpenPanes(open: 1, saved: 0), "the plan is \(String(describing: plan))")
        try check(await model.removeWorktree(made.id) == false, "removal ran while a pane was open")
        try check(await model.removeWorktree(made.id, force: true) == false, "a forced removal ran while a pane was open")
        try check(model.lastError != nil, "the refusal set no error")
        Log.line("RESULT refusal: \(model.lastError ?? "")")
        try check(fm.fileExists(atPath: made.path), "the worktree folder is gone")

        // 5. The worktree goes away while the session is closed. Resume fails, and the pane shows
        // "Session ended" with the error.
        try await app.waitUntil("the terminal has the keys") { app.window.firstResponder is TerminalSurfaceView }
        try app.type("/exit")
        app.press(.returnKey)
        try await app.waitUntil("the session ended") { app.exists("pane-ended-\(pane.uuidString)") }
        try fm.removeItem(atPath: made.path)
        app.press(.returnKey)
        try await app.waitUntil("the resume ran") { model.workspace.launch(of: pane) == 1 }
        try await app.waitUntil("the resumed pane ended") { model.workspace.session(of: pane)?.exited == true }
        let folder = URL(fileURLWithPath: made.path).lastPathComponent
        try await app.waitUntil("the bar names the gone worktree") {
            app.text(of: "pane-ended-\(pane.uuidString)")?.contains("gone") == true
        }
        try check(model.endedNote(of: pane)?.contains("fix-login") == true, "no ended note: \(model.endedNote(of: pane) ?? "none")")
        let error = try surface(pane).screenText()
        Log.line("RESULT resume error: \(error.split(separator: "\n").suffix(3).joined(separator: " | "))")
        try check(error.contains(folder), "the pane does not show the loam error that names \(folder)")
        app.screenshot("worktree-gone")

        // 6. With the pane closed, the removal goes through. The folder is gone, so nothing is lost.
        try app.pressMenuKey("w")
        try await app.waitUntil("the pane is closed") { model.workspace.paneCount(of: .plot(plot)) == 0 }
        let after = await model.planRemoval(of: made.id)
        try check(after?.needsConfirmation == true, "the plan after close is \(String(describing: after))")
        try check(await model.removeWorktree(made.id, force: true), "removal failed: \(model.lastError ?? "no error")")
        try await app.waitUntil("the sidebar row is gone") { !app.exists("worktree-\(made.id)") }
        try check(model.worktrees[plot]?.isEmpty ?? true, "the model still lists the worktree")

        // 7. Ticket 76: a second repo gets its own row under the plot. A press on the row starts a
        // session in that repo (`loam start --repo`), and the pane sits under the repo's row.
        let docs = rig.root.appendingPathComponent("docs")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try git(docs, ["init", "-q", "-b", "trunk"])
        try rig.loam(["repo", "add", plot, docs.path])
        let docsID = (try rig.show(plot)["repos"] as? [[String: Any]])?.first { $0["main"] as? Bool != true }?["id"] as? String ?? ""
        try check(!docsID.isEmpty, "the plot has no second repo")
        let docsRow = "repo-checkout-\(docsID)"
        try await app.waitUntil("the second repo row") { app.text(of: docsRow)?.contains("docs") == true }
        try check(app.text(of: docsRow)?.contains("trunk") == true, "the repo row shows \(app.text(of: docsRow) ?? "nothing")")
        try check(app.treeParent(of: docsRow) == "plot-\(plot)", "the repo row sits under \(app.treeParent(of: docsRow) ?? "nothing")")
        try app.click(docsRow)
        try await app.waitUntil("a session in the second repo") { model.workspace.paneCount(of: .plot(plot)) == 1 }
        let docsPane = try model.workspace.selectedTab(of: .plot(plot))?.focused ?? { throw DriverFailure("no pane") }()
        let docsSpec = model.workspace.spec(of: docsPane)
        try check(docsSpec?.kind == .session && docsSpec?.repo == docs.path, "the pane is not a session in docs")
        try check(docsSpec?.command?.contains("--repo") == true, "the command has no --repo: \(docsSpec?.command ?? "none")")
        try await app.waitUntil("the session started in the second repo") {
            invocation()?.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == docs.resolvingSymlinksInPath().path
        }
        try await app.waitUntil("the pane row") { app.exists("pane-row-\(docsPane.uuidString)") }
        try check(app.treeParent(of: "pane-row-\(docsPane.uuidString)") == docsRow,
                  "the docs pane sits under \(app.treeParent(of: "pane-row-\(docsPane.uuidString)") ?? "nothing")")
        app.screenshot("second-repo")

        // 8. Ticket 93: a plot session starts in the plot folder, and its pane sits right under the plot.
        model.openPlotSession(plot)
        try await app.waitUntil("a plot session") { model.workspace.paneCount(of: .plot(plot)) == 2 }
        let plotPane = try model.workspace.selectedTab(of: .plot(plot))?.focused ?? { throw DriverFailure("no pane") }()
        let plotSpec = model.workspace.spec(of: plotPane)
        try check(plotSpec?.inPlotFolder == true && plotSpec?.command?.contains("--plot-folder") == true,
                  "the pane is not a plot session: \(plotSpec?.command ?? "none")")
        try await app.waitUntil("the session started in the plot folder") {
            invocation()?.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } == plot
        }
        try await app.waitUntil("the plot pane row") { app.exists("pane-row-\(plotPane.uuidString)") }
        try check(app.treeParent(of: "pane-row-\(plotPane.uuidString)") == "plot-\(plot)",
                  "the plot session sits under \(app.treeParent(of: "pane-row-\(plotPane.uuidString)") ?? "nothing")")
        app.screenshot("plot-session")
    }
}

@MainActor
extension Scenarios {
    static func sessionWorktreeShot(_ app: DriverApp) async throws {
        do { try await sessionWorktreeShotSteps(app) } catch { app.dumpAccessibility(); throw error }
    }

    /// TAS-55: a session in the main checkout makes a worktree through MCP, as Claude does, and the sidebar shows
    /// the session under the worktree. The pane keeps its folder. MCP `work_in_worktree` with no worktree puts it
    /// back under the main checkout.
    private static func sessionWorktreeShotSteps(_ app: DriverApp) async throws {
        let (rig, environment, _) = try shotRig(app)
        // The fake claude of the rig answers `claude mcp` and exits. Here a session clears the screen and stays, so the
        // pane stays open and the shot shows no path of the machine.
        let claude = rig.root.appendingPathComponent("bin/claude")
        let mcp = try String(contentsOf: claude, encoding: .utf8).replacingOccurrences(of: "#!/bin/sh\n", with: "")
        try "#!/bin/sh\ncase \"$1\" in mcp) \(mcp)exit 0 ;; esac\nprintf '\\033[2J\\033[H'\n"
            .appending("echo 'Claude is working in the fix-login worktree.'\nexec sleep 600\n")
            .write(to: claude, atomically: true, encoding: .utf8)
        let (repo, _) = try widgetsRepo(rig, onGitHub: false)
        let plot = try rig.newPlot("Loam v1 build")
        try rig.loam(["repo", "add", plot, repo.path])
        let host = try await app.launchApp(
            client: LoamClient(binary: rig.binary, environment: environment), state: rig.stateFile, terminals: true)
        app.runtime.applyWindowAppearance(to: host.window)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let model = host.model
        try await app.waitUntil("the plot is active") { model.workspace.activePlotID == plot }

        // A session in the main checkout, with the session ID that its hooks give.
        model.openTab(.session)
        guard let pane = model.workspace.focusedPane else { throw DriverFailure("no pane") }
        let session = "cccccccc-5555-4666-8777-888888888888"
        let start = #"{"event":"SessionStart","session_id":"\#(session)","cwd":"\#(repo.path)","at":"2026-10-28T09:00:00Z","source":"startup"}"#
        model.apply(try JSONDecoder().decode(PaneEvent.self, from: Data(start.utf8)), to: pane)
        let row = "pane-row-\(pane.uuidString)"
        try await app.waitUntil("the pane sits under the main checkout") { app.treeParent(of: row) == "main-checkout-\(plot)" }

        // The session makes a worktree. It now works in it.
        let replies = try await rig.mcp([("create_worktree", ["plot": plot, "name": "fix-login", "goal": "Fix the login form"])],
                                        session: session, app: app)
        Log.line("RESULT create_worktree: \(replies.last ?? "no reply")")
        try await app.waitUntil("the worktree lists the session") {
            model.worktrees[plot]?.first { $0.worktree.branch == "fix-login" }?.worktree.sessions == [session]
        }
        guard let made = model.worktrees[plot]?.first(where: { $0.worktree.branch == "fix-login" })?.worktree else {
            throw DriverFailure("no worktree")
        }
        try await app.waitUntil("the pane moves under the worktree") { app.treeParent(of: row) == "worktree-\(made.id)" }
        try check(model.focusedWorktree?.id == made.id, "the focused worktree is \(model.focusedWorktree?.id ?? "none")")
        try check(model.workspace.spec(of: pane)?.worktree == nil, "the pane changed its folder")
        await app.sleep(0.5)
        app.screenshot("session-under-worktree")

        // work_in_worktree with no worktree: the session is back under the main checkout.
        _ = try await rig.mcp([("work_in_worktree", ["plot": plot])], session: session, app: app)
        try await app.waitUntil("the pane is back under the main checkout") { app.treeParent(of: row) == "main-checkout-\(plot)" }
        NSApp.appearance = nil
    }
}
