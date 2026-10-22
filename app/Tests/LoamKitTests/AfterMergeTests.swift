import Foundation
import Testing

@testable import LoamKit

/// What the app model did after a merge, in the order it did it.
@MainActor final class MergeRecord {
    var toasts: [(text: String, kind: ActionBarModel.ToastKind)] = []
    var prompts: [ClosePrompt] = []
    /// The answer to the "close its panes" question.
    var answer = true
    /// The shell panes that run a process, such as a dev server.
    var running: Set<PaneID> = []
}

/// Ticket 113: after a merge on GitHub. A refresh finds that GitHub merged the PR of a worktree, and the app acts as a
/// land that ticket 111 recorded says, else as the repo setting says. The worktrees come from the
/// `worktree_list_stages` fixture (made-up example/widgets data, in the plot `plotaaaaab`). `add-search` is at the
/// Merged stage with PR #11. The fake `loam` logs its arguments. Removing a worktree can lose work, so the tests that
/// matter most say what must not run. A refresh ends before its merges act, so `refresh` waits for both.
@MainActor
@Suite struct AfterMergeTests {
    let plotID = "plotaaaaab"
    /// add-search, #11, Merged. Its repo is /tmp/loam-contract/repos/web.
    let merged = "wtreaaaaac"
    /// old-theme, #12, Closed without a merge.
    let closed = "wtreaaaaad"
    /// link-labels, #22, Ready to merge.
    let ready = "wtreaaaaao"
    /// The head of PR #11 in the plans of these tests.
    let head = "1111111111111111111111111111111111111111"

    @MainActor final class Rig {
        let dir: URL
        let record = MergeRecord()
        /// The app model. `rig` sets it.
        var made: AppModel?
        var model: AppModel { made! }

        init(dir: URL) { self.dir = dir }

        func args() -> [String] {
            ((try? String(contentsOf: dir.appendingPathComponent("args.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func calls(_ command: String) -> [String] { args().filter { $0.hasPrefix(command) } }
        func removals() -> [String] { calls("worktree rm") }
        func dryRuns() -> [String] { calls("worktree land").filter { $0.contains("--dry-run") } }
        /// The lands that are not dry runs. For a PR that is not merged, one would merge it.
        func lands() -> [String] { calls("worktree land").filter { !$0.contains("--dry-run") } }
        func touch(_ name: String) throws { try Data().write(to: dir.appendingPathComponent(name)) }
        func remove(_ name: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }

        /// The rows of the next refresh and of the next read of the cache.
        func rows(_ edit: (inout [WorktreeStatus]) -> Void) throws {
            var rows = try JSONDecoder().decode([WorktreeStatus].self, from: Fixtures.data("worktree_list_stages"))
            edit(&rows)
            try JSONEncoder().encode(rows).write(to: dir.appendingPathComponent("list.json"))
            try JSONEncoder().encode(rows.filter { $0.worktree.id != "wtreaaaaac" }).write(to: dir.appendingPathComponent("after.json"))
        }

        /// The setting of the repo of add-search in `loam show`. Nil leaves the key out, as a core before ticket 113.
        func setting(_ value: AfterMerge?, whereText: String = "Building search.") throws {
            var show = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("show")) as? [String: Any])
            var repo: [String: Any] = ["id": "repoaaaaae", "path": "/tmp/loam-contract/repos/web", "note": "", "main": true, "version": 3]
            if let value { repo["after_merge"] = value.rawValue }
            show["repos"] = [repo]
            show["where_it_stands"] = whereText
            show["versions"] = ["name": 1, "what": 1, "why": 1, "where": 4, "repo:repoaaaaae": 3]
            try JSONSerialization.data(withJSONObject: show).write(to: dir.appendingPathComponent("show.json"))
        }

        /// The plan of the next dry run and the result of the next land, from the land fixture: PR #11, merged.
        func land(plan: (inout LandResult) -> Void = { _ in }, result: (inout LandResult) -> Void = { _ in }) throws {
            var base = try JSONDecoder().decode(LandResult.self, from: Fixtures.data("worktree_land"))
            let rows = try JSONDecoder().decode([WorktreeStatus].self, from: Data(contentsOf: dir.appendingPathComponent("list.json")))
            if let row = rows.first(where: { $0.worktree.id == "wtreaaaaac" }) { base.worktree = row.worktree }
            base.pr.number = 11
            base.pr.title = "Add search"
            base.pr.state = "MERGED"
            base.pr.headOID = "1111111111111111111111111111111111111111"
            base.stage = .merged
            base.merged = true
            var dry = base
            dry.dryRun = true
            dry.worktreeRemoved = false
            dry.remoteBranchDeleted = false
            dry.branchDeleted = false
            plan(&dry)
            // The app asks for a land that keeps the worktree, and removes it itself after the panes close.
            var done = base
            done.worktree.land = nil
            done.worktreeRemoved = false
            done.branchDeleted = false
            result(&done)
            try JSONEncoder().encode(dry).write(to: dir.appendingPathComponent("dry.json"))
            try JSONEncoder().encode(done).write(to: dir.appendingPathComponent("land.json"))
        }

        /// The next `loam worktree rm` fails with this message, as the core refuses work that is not on GitHub.
        func failRemoval(_ message: String) throws { try fail("rm", message) }

        /// The next `loam worktree land` that is not a dry run fails with this message.
        func failLand(_ message: String) throws { try fail("land", message) }

        private func fail(_ command: String, _ message: String) throws {
            let body = ["error": ["kind": "error", "exit_code": 1, "message": message] as [String: Any]]
            try JSONSerialization.data(withJSONObject: body).write(to: dir.appendingPathComponent("fail-\(command).json"))
            try touch("fail-\(command)")
        }

        /// `loam show` (or a dry run of `loam worktree land`) waits until `release` runs, as a slow `loam` does.
        func hold(_ name: String) throws { try touch("hold-\(name)") }
        func release(_ name: String) { remove("hold-\(name)") }

        /// Waits until the fake `loam` logged a call that starts with `command`.
        func waitForCall(_ command: String) async throws {
            let deadline = Date().addingTimeInterval(5)
            while calls(command).isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(!calls(command).isEmpty, "no call \(command)")
        }

        /// A new app model on the same fake `loam`, as after a restart.
        func restart(state: AppStateFile? = nil) async -> AppModel {
            let model = AppModel(client: LoamClient(binary: dir.appendingPathComponent("loam"), environment: [:]))
            model.shell = "/bin/zsh"
            if let state { model.startRestore(from: state, writeDelay: .milliseconds(10)) }
            model.apply([PlotSummary(id: "plotaaaaab", name: "Widgets", what: "", createdAt: "2026-01-01T00:00:00Z")])
            await model.reloadWorktrees()
            model.onToast = { [record] in record.toasts.append(($0, $1)) }
            model.confirmClose = { [record] prompt in record.prompts.append(prompt); return record.answer }
            model.paneRunsAProcess = { [record] in record.running.contains($0) }
            return model
        }
    }

    /// A model with the fixture rows, edited, and a fake `loam`. `worktree list` prints `list.json` until a removal or
    /// a land that removes ran, and `after.json` after it. A land prints `dry.json` for `--dry-run`, else `land.json`.
    /// A land with `--keep-worktree` removes nothing.
    func rig(_ setting: AfterMerge? = .ask, state: AppStateFile? = nil,
             rows edit: (inout [WorktreeStatus]) -> Void = { _ in }) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Fixtures.data("worktree_rm").write(to: dir.appendingPathComponent("rm.json"))
        let d = dir.path
        try FakeScript.install("""
            #!/bin/sh
            echo "$@" >> '\(d)/args.log'
            case "$1 $2" in
              "show "*) while [ -f '\(d)/hold-show' ]; do sleep 0.02; done
                cat '\(d)/show.json';;
              "worktree list") if [ -f '\(d)/gone' ]; then cat '\(d)/after.json'; else cat '\(d)/list.json'; fi;;
              "worktree rm") [ -f '\(d)/fail-rm' ] && { cat '\(d)/fail-rm.json'; exit 1; }
                touch '\(d)/gone'
                cat '\(d)/rm.json';;
              "worktree land")
                case "$*" in
                  *--dry-run*) while [ -f '\(d)/hold-dry' ]; do sleep 0.02; done
                    if [ -f "\(d)/dry-$4.json" ]; then cat "\(d)/dry-$4.json"; else cat '\(d)/dry.json'; fi;;
                  *) [ -f '\(d)/fail-land' ] && { cat '\(d)/fail-land.json'; exit 1; }
                    case "$*" in *--keep-worktree*) ;; *) touch '\(d)/gone';; esac
                    if [ -f "\(d)/land-$4.json" ]; then cat "\(d)/land-$4.json"; else cat '\(d)/land.json'; fi;;
                esac;;
              *) exit 1;;
            esac
            """, at: dir.appendingPathComponent("loam"))
        let rig = Rig(dir: dir)
        try rig.rows(edit)
        try rig.setting(setting)
        try rig.land()
        rig.made = await rig.restart(state: state)
        return rig
    }

    func refresh(_ rig: Rig) async { await refresh(rig.model) }

    func refresh(_ model: AppModel) async {
        await model.refreshWorktrees(plot: plotID)
        await model.mergesSettled()
    }

    /// Opens a pane in a worktree. A session pane starts idle; `turn` puts it mid-turn, or makes it need you.
    func pane(in id: String, _ model: AppModel, _ kind: PaneSpec.Kind = .shell, turn: String? = nil) throws -> PaneID {
        model.openWorktreePane(try #require(model.worktreeStatus(id)?.worktree), kind: kind)
        let pane = try #require(model.workspace.focusedPane)
        if kind == .session {
            let session = model.workspace.session(of: pane)?.sessionID ?? ""
            model.apply(paneEvent("SessionStart", session, source: "startup"), to: pane)
            if let turn { model.apply(paneEvent(turn, session), to: pane) }
        }
        return pane
    }

    func edit(_ id: String, _ rows: inout [WorktreeStatus], _ change: (inout WorktreeStatus) -> Void) {
        if let i = rows.firstIndex(where: { $0.worktree.id == id }) { change(&rows[i]) }
    }

    // MARK: The setting

    @Test func askShowsACalloutAndRemovesNothing() async throws {
        let rig = try await rig(.ask)
        await refresh(rig)
        let merge = MergedPR(worktree: merged, number: 11)
        #expect(rig.model.mergeAsks == [merge])
        #expect(rig.model.mergeAsks(in: plotID) == [merge] && rig.model.mergeAsks(in: "plotaaaaac").isEmpty)
        #expect(AfterMergeRule.question(merge, name: "add-search") == "#11 was merged on GitHub. Remove the worktree add-search?")
        #expect(rig.removals().isEmpty && rig.calls("worktree land").isEmpty)
        #expect(rig.record.toasts.isEmpty, "a merge is not news that Loam tells: the callout asks")
        #expect(rig.model.worktreeStatus(merged)?.stage == .merged)
    }

    @Test func aCoreWithNoSettingAsks() async throws {
        let rig = try await rig(nil)
        await refresh(rig)
        #expect(rig.model.mergeAsks == [MergedPR(worktree: merged, number: 11)])
        #expect(rig.removals().isEmpty)
    }

    @Test func removeTheWorktreeClosesItsPanesAndRemovesACleanWorktree() async throws {
        let rig = try await rig(.remove)
        let model = rig.model
        let shell = try pane(in: merged, model)
        let session = try pane(in: merged, model, .session)
        let other = try pane(in: ready, model)
        await refresh(rig)
        let otherFolder = try #require(model.workspace.folder(of: other))
        #expect(rig.removals() == ["worktree rm \(plotID) \(merged) --open-pane \(otherFolder) --json --actor app"],
                "no --force, and no pane of the worktree, since its panes closed first")
        #expect(!model.workspace.allPaneIDs.contains(shell) && !model.workspace.allPaneIDs.contains(session))
        #expect(model.workspace.allPaneIDs.contains(other), "a pane of another worktree stays")
        #expect(rig.record.prompts.isEmpty, "an idle session and a shell at its prompt ask nothing")
        #expect(rig.record.toasts.map(\.text) == ["#11 was merged on GitHub. Loam removed the worktree add-search."])
        #expect(rig.record.toasts.first?.kind == .done)
        #expect(model.mergeAsks.isEmpty && model.worktreeStatus(merged) == nil)
        #expect(rig.calls("worktree land").isEmpty)
    }

    enum Unsafe: String, CaseIterable, Sendable {
        case changedFiles, unpushedCommits, failedCheck, sessionInATurn, sessionNeedsYou, shellRunsAProcess
    }

    /// Remove the worktree falls back to Ask when the worktree holds work that is not on GitHub, a session works in it,
    /// or a shell in it runs a process, such as a dev server. The core gives no Merged stage with changed files, so the
    /// changed files here come from a row that says so anyway.
    @Test(arguments: Unsafe.allCases)
    func removeTheWorktreeAsksWhenItIsNotSafe(_ unsafe: Unsafe) async throws {
        let rig = try await rig(.remove) { rows in
            edit(merged, &rows) { row in
                switch unsafe {
                case .changedFiles: row.changed = 2
                case .unpushedCommits: row.unpushed = 1
                case .failedCheck: row.error = "git status failed"
                case .sessionInATurn, .sessionNeedsYou, .shellRunsAProcess: break
                }
            }
        }
        let model = rig.model
        let shell = try pane(in: merged, model)
        if unsafe == .shellRunsAProcess { rig.record.running.insert(shell) }
        var session: PaneID?
        if unsafe == .sessionInATurn { session = try pane(in: merged, model, .session, turn: "UserPromptSubmit") }
        if unsafe == .sessionNeedsYou { session = try pane(in: merged, model, .session, turn: "PermissionRequest") }
        await refresh(rig)
        #expect(rig.removals().isEmpty && rig.calls("worktree land").isEmpty, "Loam removed a worktree that was not safe")
        #expect(model.mergeAsks == [MergedPR(worktree: merged, number: 11)])
        #expect(model.workspace.allPaneIDs.contains(shell), "a pane closed")
        if let session { #expect(model.workspace.allPaneIDs.contains(session), "the session closed") }
        #expect(rig.record.prompts.isEmpty && rig.record.toasts.isEmpty)
    }

    /// With no terminal to ask, the app counts a shell as running a process, so Remove the worktree asks.
    @Test func aModelWithNoTerminalsCountsEachShellAsRunning() {
        let model = AppModel(client: LoamClient(binary: URL(fileURLWithPath: "/usr/bin/false"), environment: [:]))
        #expect(model.paneRunsAProcess(PaneID()))
    }

    /// The core refuses too, such as for a file that changed after the refresh. Then the app asks.
    @Test func removeTheWorktreeAsksWhenTheCoreRefuses() async throws {
        let rig = try await rig(.remove)
        try rig.failRemoval("add-search has 1 file(s) with uncommitted changes. Commit or stash them, or remove it with --force")
        await refresh(rig)
        #expect(rig.removals().count == 1 && !rig.removals()[0].contains("--force"))
        #expect(rig.model.mergeAsks == [MergedPR(worktree: merged, number: 11)])
        #expect(rig.model.worktreeStatus(merged) != nil && rig.record.toasts.isEmpty)
    }

    @Test func doNothingLeavesTheFadedRow() async throws {
        let rig = try await rig(.keep)
        await refresh(rig)
        #expect(rig.model.mergeAsks.isEmpty)
        #expect(rig.removals().isEmpty && rig.calls("worktree land").isEmpty && rig.record.toasts.isEmpty)
        #expect(rig.model.worktreeStatus(merged)?.stage == .merged)
    }

    enum NotMerged: String, CaseIterable, Sendable { case stateOpen, stateClosed, noPR, workAfterThePR, closedStage, folderGone }

    /// Only a PR whose state is MERGED counts, at the Merged stage, with the folder there. Nothing else reads the setting.
    @Test(arguments: NotMerged.allCases)
    func onlyAPRWhoseStateIsMergedCounts(_ variant: NotMerged) async throws {
        let rig = try await rig(.remove) { rows in
            edit(merged, &rows) { row in
                switch variant {
                case .stateOpen: row.pr?.state = "OPEN"
                case .stateClosed: row.pr?.state = "CLOSED"
                case .noPR: row.pr = nil
                case .workAfterThePR: row.stage = .notPushed; row.pr = nil; row.changed = 1
                case .closedStage: row.stage = .closed
                case .folderGone: row.missing = true
                }
            }
        }
        await refresh(rig)
        #expect(rig.removals().isEmpty && rig.calls("worktree land").isEmpty)
        #expect(rig.model.mergeAsks.isEmpty)
        #expect(rig.calls("show").isEmpty, "a row that is not merged read the setting")
    }

    @Test func aPRClosedWithoutAMergeDoesNothing() async throws {
        let rig = try await rig(.remove)
        await refresh(rig)
        #expect(rig.model.worktreeStatus(closed)?.stage == .closed)
        #expect(!rig.model.mergeAsks.contains { $0.worktree == closed })
        #expect(rig.removals().allSatisfy { !$0.contains(closed) })
    }

    /// A refresh that got no answer from GitHub gives the cached rows, with a note. A merge in a cache does not act: the
    /// app waits for an answer of GitHub.
    @Test(arguments: PRNote.allCases.filter { $0 != .noNote })
    func aRefreshWithNoAnswerOfGitHubDoesNotAct(_ note: PRNote) async throws {
        let rig = try await rig(.remove) { rows in edit(merged, &rows) { $0.prNote = note } }
        await refresh(rig)
        #expect(rig.calls("show").isEmpty && rig.removals().isEmpty && rig.model.mergeAsks.isEmpty)
        try rig.rows { rows in edit(merged, &rows) { $0.prNote = .noNote } }
        await refresh(rig)
        #expect(rig.removals().count == 1, "the merge did not act after GitHub answered")
    }

    /// The spinner of a refresh does not wait for what the merge does, and a second refresh meanwhile decides nothing
    /// again.
    @Test(.timeLimit(.minutes(1))) func theRefreshEndsBeforeItsMergeActs() async throws {
        let rig = try await rig(.remove)
        let model = rig.model
        try rig.hold("show")
        #expect(model.openPullRequest(merged))
        #expect(await model.refreshWorktree(merged))
        #expect(!model.prPopover.isRefreshing, "the refresh waits for the merge")
        await model.refreshWorktrees(plot: plotID)
        try await rig.waitForCall("show")
        #expect(rig.removals().isEmpty)
        rig.release("show")
        await model.mergesSettled()
        #expect(rig.calls("show").count == 1 && rig.removals().count == 1)
    }

    @Test func eachMergeActsOnce() async throws {
        let rig = try await rig(.remove)
        try rig.failRemoval("add-search has 1 commit(s) that are not pushed")
        await refresh(rig)
        await refresh(rig)
        await rig.model.refreshWorktree(merged)
        await rig.model.mergesSettled()
        #expect(rig.calls("show").count == 1, "each refresh read the setting again")
        #expect(rig.removals().count == 1, "each refresh tried again")
        #expect(rig.model.mergeAsks == [MergedPR(worktree: merged, number: 11)])
    }

    // MARK: A recorded land

    func recorded(_ pr: Int, keepWorktree: Bool = false, keepRemoteBranch: Bool = false) -> PendingLand {
        PendingLand(pr: pr, method: "", auto: true, mergeQueue: false, keepWorktree: keepWorktree, keepRemoteBranch: keepRemoteBranch)
    }

    /// A land that ticket 111 recorded for PR #11 tidies up as it says, whatever the setting. A dry run comes first, and
    /// the land names the head of the merged PR. The land keeps the worktree, so it needs no closed pane. Then the panes
    /// close, and `loam worktree rm` removes the worktree, as the land would.
    @Test(arguments: [AfterMerge.ask, .remove, .keep])
    func aRecordedLandWinsOverTheSetting(_ setting: AfterMerge) async throws {
        let land = recorded(11)
        let rig = try await rig(setting) { rows in edit(merged, &rows) { $0.worktree.land = land } }
        try rig.land()
        let shell = try pane(in: merged, rig.model)
        await refresh(rig)
        #expect(rig.dryRuns() == ["worktree land \(plotID) \(merged) --dry-run --json --actor app"])
        #expect(rig.lands() == ["worktree land \(plotID) \(merged) --keep-worktree --head \(head) --json --actor app"],
                "the core applies the keep of the branch on GitHub that the worktree records")
        #expect(rig.removals() == ["worktree rm \(plotID) \(merged) --json --actor app"], "no --force")
        let order = rig.args().filter { $0.hasPrefix("worktree land") || $0.hasPrefix("worktree rm") }
        #expect(order.last?.hasPrefix("worktree rm") == true, "the removal ran before the land")
        #expect(rig.calls("show").isEmpty, "the setting was read")
        #expect(rig.model.mergeAsks.isEmpty)
        #expect(!rig.model.workspace.allPaneIDs.contains(shell), "the pane of the worktree stays open after the removal")
        #expect(rig.record.toasts.map(\.text) == ["Merged #11. Removed the worktree add-search."])
        #expect(rig.model.worktreeStatus(merged) == nil)
    }

    /// A land that the core refuses leaves every pane open, since no pane closes before the land.
    @Test func aRecordedLandThatTheCoreRefusesLeavesEveryPaneOpen() async throws {
        let rig = try await rig(.remove) { rows in edit(merged, &rows) { $0.worktree.land = recorded(11) } }
        try rig.land()
        try rig.failLand("gh stopped before GitHub answered")
        let shell = try pane(in: merged, rig.model)
        await refresh(rig)
        #expect(rig.lands().count == 1 && rig.removals().isEmpty)
        #expect(rig.model.workspace.allPaneIDs.contains(shell), "a pane closed before a land that failed")
        #expect(rig.model.mergeAsks == [MergedPR(worktree: merged, number: 11)])
        #expect(rig.record.toasts.isEmpty)
    }

    /// The land tidied up, and the core refuses the removal after it. The worktree stays, and the callout asks.
    @Test func aRecordedLandWhoseRemovalTheCoreRefusesAsks() async throws {
        let rig = try await rig(.remove) { rows in edit(merged, &rows) { $0.worktree.land = recorded(11) } }
        try rig.land()
        try rig.failRemoval("add-search has 1 file(s) with uncommitted changes")
        await refresh(rig)
        #expect(rig.lands().count == 1 && rig.removals().count == 1)
        #expect(rig.model.mergeAsks == [MergedPR(worktree: merged, number: 11)])
        #expect(rig.record.toasts.map(\.text) == ["Merged #11. Loam kept the worktree add-search."])
        #expect(rig.record.toasts.first?.kind == .notice)
    }

    /// A land that the worktree records for another PR is stale. The setting decides, and no land runs.
    @Test func aRecordedLandOfAnotherPRDoesNotApply() async throws {
        let rig = try await rig(.ask) { rows in edit(merged, &rows) { $0.worktree.land = recorded(9) } }
        await refresh(rig)
        #expect(rig.calls("worktree land").isEmpty)
        #expect(rig.model.mergeAsks == [MergedPR(worktree: merged, number: 11)])

        let removing = try await self.rig(.remove) { rows in edit(merged, &rows) { $0.worktree.land = recorded(9, keepWorktree: true) } }
        await refresh(removing)
        #expect(removing.calls("worktree land").isEmpty, "a stale keep applied")
        #expect(removing.removals() == ["worktree rm \(plotID) \(merged) --json --actor app"])
    }

    enum OddPlan: String, CaseIterable, Sendable { case open, otherNumber, noRecord, recordOfAnotherPR }

    /// A land of a PR that is not merged would merge it. The land runs only after a dry run says that the PR is merged,
    /// with the same number, and that the record is for it.
    @Test(arguments: OddPlan.allCases)
    func aRecordedLandRunsOnlyAfterADryRunSaysMerged(_ odd: OddPlan) async throws {
        let rig = try await rig(.keep) { rows in edit(merged, &rows) { $0.worktree.land = recorded(11) } }
        try rig.land(plan: { plan in
            switch odd {
            case .open: plan.merged = false; plan.pr.state = "OPEN"; plan.stage = .readyToMerge
            case .otherNumber: plan.pr.number = 31
            case .noRecord: plan.worktree.land = nil
            case .recordOfAnotherPR: plan.worktree.land?.pr = 9
            }
        })
        await refresh(rig)
        #expect(rig.dryRuns().count == 1)
        #expect(rig.lands().isEmpty, "a land ran after a dry run that did not say merged")
        #expect(rig.model.mergeAsks == [MergedPR(worktree: merged, number: 11)])
    }

    /// A recorded land that removes the worktree follows the same rules as Remove the worktree.
    @Test(arguments: [Unsafe.unpushedCommits, .sessionInATurn, .shellRunsAProcess])
    func aRecordedLandThatRemovesAsksWhenItIsNotSafe(_ unsafe: Unsafe) async throws {
        let rig = try await rig(.remove) { rows in
            edit(merged, &rows) { row in
                row.worktree.land = recorded(11)
                if unsafe == .unpushedCommits { row.unpushed = 2 }
            }
        }
        try rig.land()
        if unsafe == .sessionInATurn { _ = try pane(in: merged, rig.model, .session, turn: "UserPromptSubmit") }
        if unsafe == .shellRunsAProcess { rig.record.running.insert(try pane(in: merged, rig.model)) }
        await refresh(rig)
        #expect(rig.lands().isEmpty && rig.removals().isEmpty)
        #expect(rig.model.mergeAsks == [MergedPR(worktree: merged, number: 11)])
        #expect(rig.record.prompts.isEmpty)
    }

    /// A recorded land that keeps the worktree removes nothing, so a session in a turn stays and the land runs. Loam
    /// remembers the keep, so no callout asks later.
    @Test func aRecordedLandThatKeepsTheWorktreeTidiesUpAndAsksNothing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("merge-state-\(UUID().uuidString)")
        let state = AppStateFile(url: folder.appendingPathComponent("state.json"))
        let land = recorded(11, keepWorktree: true)
        let rig = try await rig(.ask, state: state) { rows in edit(merged, &rows) { $0.worktree.land = land } }
        try rig.land()
        let session = try pane(in: merged, rig.model, .session, turn: "UserPromptSubmit")
        await refresh(rig)
        #expect(rig.lands().count == 1 && rig.removals().isEmpty)
        #expect(rig.model.workspace.allPaneIDs.contains(session))
        #expect(rig.model.mergeAsks.isEmpty && rig.model.keptMerges.contains(MergedPR(worktree: merged, number: 11)))
        #expect(rig.record.toasts.map(\.text) == ["Merged #11."])
        // The land cleared the record. After a restart, the worktree still asks nothing.
        rig.model.stateWriter?.flush()
        try rig.rows { _ in }
        let restarted = await rig.restart(state: state)
        await refresh(restarted)
        #expect(restarted.mergeAsks.isEmpty && rig.lands().count == 1 && rig.removals().isEmpty)
    }

    // MARK: Keep

    @Test func keepIsRememberedAfterARestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("merge-state-\(UUID().uuidString)")
        let state = AppStateFile(url: folder.appendingPathComponent("state.json"))
        let rig = try await rig(.ask, state: state)
        await refresh(rig)
        rig.model.keepMerged(merged)
        #expect(rig.model.mergeAsks.isEmpty)
        #expect(rig.model.worktreeStatus(merged)?.stage == .merged, "Keep removed the worktree")
        rig.model.stateWriter?.flush()
        #expect((state.value(forKey: KeptMerges.key) as? [String: Int]) == [merged: 11])

        let restarted = await rig.restart(state: state)
        await refresh(restarted)
        #expect(restarted.mergeAsks.isEmpty, "the kept merge asked again after a restart")
        #expect(rig.removals().isEmpty)

        // A new PR of the same worktree is a new merge.
        try rig.rows { rows in edit(merged, &rows) { $0.pr?.number = 31 } }
        let later = await rig.restart(state: state)
        await refresh(later)
        #expect(later.mergeAsks == [MergedPR(worktree: merged, number: 31)])
    }

    @Test func aKeepOfAWorktreeThatIsGoneIsDropped() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("merge-state-\(UUID().uuidString)")
        let state = AppStateFile(url: folder.appendingPathComponent("state.json"))
        let rig = try await rig(.ask, state: state)
        await refresh(rig)
        rig.model.keepMerged(merged)
        try rig.touch("gone")
        await rig.model.reloadWorktrees()
        rig.model.stateWriter?.flush()
        #expect((state.value(forKey: KeptMerges.key) as? [String: Int]) == [:])
    }

    // MARK: The callout

    @Test func removeWorktreeInTheCalloutPrefillsWhereItStands() async throws {
        let rig = try await rig(.ask)
        let model = rig.model
        let shell = try pane(in: merged, model)
        await model.panel.load(plotID: plotID)
        await refresh(rig)
        await model.removeMergedWorktree(merged)
        #expect(rig.removals() == ["worktree rm \(plotID) \(merged) --json --actor app"])
        #expect(!model.workspace.allPaneIDs.contains(shell))
        #expect(model.mergeAsks.isEmpty && model.worktreeStatus(merged) == nil)
        #expect(model.panel.shownText(of: .whereItStands) == "Merged #11 Add search. Building search.")
        #expect(model.panel.whereSelection?.sentence == "Merged #11 Add search.")
        #expect(model.panel.drafts[.whereItStands]?.base == 4, "⌘Return saves with --expect of the version it read")
        #expect(rig.calls("set").isEmpty, "Where it stands saved with no ⌘Return")
        #expect(rig.record.toasts.isEmpty)
    }

    @Test func removeWorktreeInTheCalloutAsksForASessionInATurn() async throws {
        let rig = try await rig(.ask)
        let model = rig.model
        let session = try pane(in: merged, model, .session, turn: "UserPromptSubmit")
        await refresh(rig)
        rig.record.answer = false
        await model.removeMergedWorktree(merged)
        let prompt = try #require(rig.record.prompts.first)
        #expect(prompt.title == "Close its panes and remove the worktree?" && prompt.confirm == "Close and remove")
        #expect(prompt.message == "1 session in this worktree is mid-turn. If you remove the worktree, the session stops and loses its partial reply.")
        #expect(rig.removals().isEmpty && model.workspace.allPaneIDs.contains(session))
        #expect(model.mergeAsks == [MergedPR(worktree: merged, number: 11)], "Cancel took the callout away")

        rig.record.answer = true
        await model.removeMergedWorktree(merged)
        #expect(rig.removals().count == 1 && !model.workspace.allPaneIDs.contains(session))
        #expect(model.mergeAsks.isEmpty)
    }

    @Test func aRefusalOfTheCoreShowsInThePanelAndTheCalloutStays() async throws {
        let rig = try await rig(.ask)
        let model = rig.model
        await model.panel.load(plotID: plotID)
        await refresh(rig)
        try rig.failRemoval("add-search has 1 file(s) with uncommitted changes")
        await model.removeMergedWorktree(merged)
        #expect(model.panel.errorMessage?.contains("uncommitted changes") == true)
        #expect(model.mergeAsks == [MergedPR(worktree: merged, number: 11)])
        #expect(model.panel.drafts[.whereItStands] == nil && model.panel.whereSelection == nil)
    }

    /// Remove worktree in the callout refuses work that the app knows is not on GitHub before it asks or closes a pane.
    @Test(arguments: [Unsafe.changedFiles, .unpushedCommits, .failedCheck])
    func removeWorktreeInTheCalloutRefusesWorkThatIsNotOnGitHub(_ unsafe: Unsafe) async throws {
        let rig = try await rig(.ask) { rows in
            edit(merged, &rows) { row in
                switch unsafe {
                case .changedFiles: row.changed = 2
                case .unpushedCommits: row.unpushed = 1
                default: row.error = "git status failed"
                }
            }
        }
        let model = rig.model
        let shell = try pane(in: merged, model)
        let session = try pane(in: merged, model, .session, turn: "UserPromptSubmit")
        await model.panel.load(plotID: plotID)
        await refresh(rig)
        await model.removeMergedWorktree(merged)
        #expect(rig.removals().isEmpty && rig.record.prompts.isEmpty)
        #expect(model.workspace.allPaneIDs.contains(shell) && model.workspace.allPaneIDs.contains(session))
        let message = switch unsafe {
        case .changedFiles: "In the worktree add-search, 2 files have uncommitted changes. Removing it loses that work."
        case .unpushedCommits: "In the worktree add-search, 1 commit is not pushed. Removing it loses that work."
        default: "A check failed: git status failed. Loam cannot tell if the work is safe."
        }
        #expect(model.panel.errorMessage == message)
        #expect(model.mergeAsks == [MergedPR(worktree: merged, number: 11)])
    }

    /// The panel shows a refusal only while it shows the plot of the worktree.
    @Test func aRefusalShowsOnlyInThePanelOfThePlot() async throws {
        let rig = try await rig(.ask)
        let model = rig.model
        await refresh(rig)
        try rig.failRemoval("add-search has 1 file(s) with uncommitted changes")
        await model.removeMergedWorktree(merged)
        #expect(rig.removals().count == 1)
        #expect(model.panel.plot == nil && model.panel.errorMessage == nil)
        #expect(model.mergeAsks == [MergedPR(worktree: merged, number: 11)])
    }

    @Test func keepInTheCalloutLeavesTheWorktree() async throws {
        let rig = try await rig(.ask)
        await refresh(rig)
        rig.model.keepMerged(merged)
        #expect(rig.model.mergeAsks.isEmpty && rig.model.keptMerges.contains(MergedPR(worktree: merged, number: 11)))
        #expect(rig.model.worktreeStatus(merged)?.stage == .merged && rig.removals().isEmpty)
    }

    @Test func theCalloutGoesWhenTheWorktreeLeaves() async throws {
        let rig = try await rig(.ask)
        await refresh(rig)
        #expect(rig.model.mergeAsks.count == 1)
        try rig.touch("gone")
        await rig.model.reloadWorktrees()
        #expect(rig.model.mergeAsks.isEmpty)
    }

    // MARK: The Land sheet

    /// A merge of the Land sheet tidies up itself. While it runs, a refresh leaves the worktree alone.
    @Test func aRefreshLeavesAWorktreeThatTheLandSheetMergesNow() async throws {
        let rig = try await rig(.remove)
        let model = rig.model
        model.landSheet.open(merged)
        model.landSheet.beginMerging()
        await refresh(rig)
        #expect(rig.calls("show").isEmpty && rig.removals().isEmpty && model.mergeAsks.isEmpty)
        model.landSheet.endMerging()
        model.landSheet.close()
        await refresh(rig)
        #expect(rig.removals().count == 1, "the merge waited for the land, and acts after it")
    }

    /// A land of the Land sheet that starts while the app reads the setting wins. The merge decides again later.
    @Test func aLandSheetMergeThatStartsDuringTheSettingReadWins() async throws {
        let rig = try await rig(.remove)
        let model = rig.model
        let shell = try pane(in: merged, model)
        try rig.hold("show")
        await model.refreshWorktrees(plot: plotID)
        try await rig.waitForCall("show")
        model.landSheet.open(merged)
        model.landSheet.beginMerging()
        rig.release("show")
        await model.mergesSettled()
        #expect(rig.removals().isEmpty && model.mergeAsks.isEmpty)
        #expect(model.workspace.allPaneIDs.contains(shell), "a pane closed under the land of the sheet")
        model.landSheet.endMerging()
        model.landSheet.close()
        await refresh(rig)
        #expect(rig.removals().count == 1, "the merge did not decide again after the land")
    }

    /// A land of the Land sheet that starts during the dry run of a recorded land wins.
    @Test func aLandSheetMergeThatStartsDuringTheDryRunWins() async throws {
        let rig = try await rig(.ask) { rows in edit(merged, &rows) { $0.worktree.land = recorded(11) } }
        let model = rig.model
        try rig.land()
        try rig.hold("dry")
        await model.refreshWorktrees(plot: plotID)
        try await rig.waitForCall("worktree land")
        model.landSheet.open(merged)
        model.landSheet.beginMerging()
        rig.release("dry")
        await model.mergesSettled()
        #expect(rig.lands().isEmpty && rig.removals().isEmpty && model.mergeAsks.isEmpty)
        model.landSheet.endMerging()
        model.landSheet.close()
        await refresh(rig)
        #expect(rig.lands().count == 1, "the merge did not decide again after the land")
    }

    /// A merge of the Land sheet with the first box off keeps the worktree. Its row is Merged after it, and no callout
    /// asks about it, whatever the setting.
    @Test func aWorktreeThatTheLandSheetKeptAsksNothing() async throws {
        let rig = try await rig(.remove)
        let model = rig.model
        try JSONDecoder().decode(LandResult.self, from: Fixtures.data("worktree_land_dry_run")).write(rig, as: "dry-\(ready).json")
        var landed = try JSONDecoder().decode(LandResult.self, from: Fixtures.data("worktree_land"))
        landed.worktreeRemoved = false
        landed.branchDeleted = false
        try landed.write(rig, as: "land-\(ready).json")
        #expect(model.openLandSheet(ready))
        let deadline = Date().addingTimeInterval(5)
        while model.landSheet.plan == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        model.landSheet.removesWorktree = false
        await model.land()
        #expect(rig.lands().count == 1 && rig.lands()[0].contains("--keep-worktree"))
        #expect(model.keptMerges.contains(MergedPR(worktree: ready, number: 22)))
        // GitHub says merged now.
        try rig.rows { rows in
            edit(ready, &rows) { row in
                row.stage = .merged
                row.pr?.state = "MERGED"
            }
        }
        await refresh(rig)
        #expect(!model.mergeAsks.contains { $0.worktree == ready })
        #expect(rig.removals().allSatisfy { !$0.contains(ready) }, "a worktree that you kept was removed")
    }
}

private extension LandResult {
    @MainActor func write(_ rig: AfterMergeTests.Rig, as name: String) throws {
        try JSONEncoder().encode(self).write(to: rig.dir.appendingPathComponent(name))
    }
}
