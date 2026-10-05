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

    /// Runs git in a folder with no global config, so the host's signing and hooks do not matter.
    private static func git(_ folder: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Driver", "-c", "user.email=driver@example.com",
                             "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
        process.currentDirectoryURL = folder
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": folder.path,
                               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw DriverFailure("git \(args.joined(separator: " ")) failed in \(folder.path)") }
    }

    /// One MCP call as Claude would make it. The setup command that it sets is not approved.
    private static func mcpCall(_ rig: PanelRig, _ tool: String, _ arguments: [String: Any]) async throws {
        let process = Process()
        process.executableURL = rig.binary
        process.arguments = ["mcp"]
        process.environment = ProcessInfo.processInfo.environment.merging(rig.environment) { $1 }
            .merging(["CLAUDE_CODE_SESSION_ID": "cccccccc-1111-4222-8333-444444444444"]) { $1 }
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        try process.run()
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try stdin.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [String: Any](),
            "clientInfo": ["name": "loam-driver", "version": "1"]]])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])
        try await Task.sleep(for: .milliseconds(600))
        try stdin.fileHandleForWriting.close()
        for _ in 0..<100 where process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        if process.isRunning { process.terminate() }
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
        try "".write(to: rig.fakeHome.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
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
        try await mcpCall(rig, "update_repo", ["plot": plot, "repo_id": repoID, "setup": "echo ran > setup-marker"])

        let environment = rig.environment.merging([
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

        // 1. A new worktree opens a seeded pane in it. The sidebar lists it under the plot.
        guard let made = await model.newWorktree(in: plot, named: "fix-login") else {
            throw DriverFailure("no worktree: \(model.lastError ?? "no error")")
        }
        Log.line("RESULT worktree: \(made.path) branch \(made.branch)")
        try check(fm.fileExists(atPath: made.path + "/README.md"), "the worktree folder has no checkout")
        let pane = try model.workspace.selectedTab(of: plot)?.focused ?? { throw DriverFailure("no pane") }()
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
        try await app.waitUntil("the pane is closed") { model.workspace.paneCount(of: plot) == 0 }
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
        try await app.waitUntil("a session in the second repo") { model.workspace.paneCount(of: plot) == 1 }
        let docsPane = try model.workspace.selectedTab(of: plot)?.focused ?? { throw DriverFailure("no pane") }()
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
        try await app.waitUntil("a plot session") { model.workspace.paneCount(of: plot) == 2 }
        let plotPane = try model.workspace.selectedTab(of: plot)?.focused ?? { throw DriverFailure("no pane") }()
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
