import Foundation
import Testing

@testable import LoamKit

/// What the app model did for the Land sheet, in the order it did it.
@MainActor final class LandRecord {
    var toasts: [(text: String, kind: ActionBarModel.ToastKind)] = []
    var ownChanges: [Int] = []
    var prompts: [ClosePrompt] = []
    /// The calls of the "close its panes" question, answered with `answer`.
    var answer = true
    /// The question stays up while this is true.
    var holdsTheQuestion = false
    /// The panes of the worktree that were still open when the views were told to finish closing, and how many
    /// real lands had run by then.
    var panesAtFinish: Int?
    var landsAtFinish: Int?
}

/// Ticket 112: the app model opens the Land sheet, reads the plan, and runs the merge through `loam`. The worktrees
/// come from the `worktree_list_stages` fixture (made-up example/widgets data, all in the plot `plotaaaaab`), and the
/// plans from the land fixtures. The fake `loam` logs its arguments, so a test can say which commands ran and in
/// which order. The merge cannot be undone, so the tests that matter most say what must not run.
@MainActor
@Suite(.waitLimit) struct LandSheetModelTests {
    let plotID = "plotaaaaab"
    /// link-labels, #22, Ready to merge. Its path is `web-link-labels`.
    let ready = "wtreaaaaao"
    /// native-panel, #16, Checks failed.
    let failed = "wtreaaaaah"
    /// pushed-only, no PR.
    let noPR = "wtreaaaaap"
    /// The PR head of the plan that the fixture `worktree_land_dry_run` holds. Each land names it with `--head`, so a
    /// commit that GitHub got after the sheet read the PR is never merged unseen.
    let head = "2222222222222222222222222222222222222222"

    struct Rig {
        let dir: URL
        let model: AppModel
        let record: LandRecord

        func args() -> [String] {
            ((try? String(contentsOf: dir.appendingPathComponent("args.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func dryRuns() -> [String] { args().filter { $0.hasPrefix("worktree land") && $0.contains("--dry-run") } }
        /// The lands that merge: `worktree land` with no `--dry-run`.
        func lands() -> [String] { args().filter { $0.hasPrefix("worktree land") && !$0.contains("--dry-run") } }
        func calls(_ command: String) -> [String] { args().filter { $0.hasPrefix(command) } }

        func write(_ name: String, _ data: Data) throws { try data.write(to: dir.appendingPathComponent(name)) }
        func touch(_ name: String, _ text: String = "") throws { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
        func remove(_ name: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        func read(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }

        /// The plan that the next dry run prints.
        func plan(_ edit: (inout LandResult) -> Void = { _ in }) throws {
            var plan = try JSONDecoder().decode(LandResult.self, from: Fixtures.data("worktree_land_dry_run"))
            edit(&plan)
            try write("dry.json", JSONEncoder().encode(plan))
        }

        /// Makes the real land fail with the error body in the fixture, or with a message of GitHub.
        func failLand(code: Int, message: String) throws {
            let body = ["error": ["kind": code == 16 ? "not_ready" : "error", "exit_code": code, "message": message] as [String: Any]]
            try write("fail-land.json", JSONSerialization.data(withJSONObject: body))
            try touch("fail-land", "\(code)")
        }
    }

    func plot(_ id: String) -> PlotSummary { PlotSummary(id: id, name: "Widgets", what: "", createdAt: "2026-01-01T00:00:00Z") }

    /// A model with the fixture rows and a fake `loam`. Reads of the plan print `dry.json`, the real land prints
    /// `land.json`, and the list loses the worktree once a real land has run (`landed`).
    func rig(whereText: String = "Native panel spacing fails lint.", whereVersion: Int = 4) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("land-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rows = try Fixtures.data("worktree_list_stages")
        try rows.write(to: dir.appendingPathComponent("list.json"))
        let left = try (JSONSerialization.jsonObject(with: rows) as? [[String: Any]] ?? []).filter {
            (($0["worktree"] as? [String: Any])?["id"] as? String) != ready
        }
        try JSONSerialization.data(withJSONObject: left).write(to: dir.appendingPathComponent("list-after.json"))
        for name in ["worktree_land", "worktree_land_auto", "worktree_update", "error_gh_unavailable", "error_not_ready", "set"] {
            try Fixtures.data(name).write(to: dir.appendingPathComponent("\(name).json"))
        }
        try Fixtures.data("worktree_land").write(to: dir.appendingPathComponent("land.json"))
        var show = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("show")) as? [String: Any])
        show["where_it_stands"] = whereText
        show["versions"] = ["name": 1, "what": 1, "why": 1, "where": whereVersion]
        try JSONSerialization.data(withJSONObject: show).write(to: dir.appendingPathComponent("show.json"))
        let d = dir.path
        try FakeScript.install("""
            #!/bin/sh
            echo "$@" >> '\(d)/args.log'
            case "$1 $2" in
              "show "*) cat '\(d)/show.json';;
              "set "*) cat > '\(d)/set.stdin'
                [ -f '\(d)/fail-set' ] && { cat '\(d)/fail-set.json'; exit "$(cat '\(d)/fail-set')"; }
                cat '\(d)/set.json';;
              "worktree land")
                case "$*" in
                  *--dry-run*) [ -f '\(d)/fail-dry' ] && { cat '\(d)/error_gh_unavailable.json'; exit 17; }
                    while [ -f '\(d)/hold-dry' ]; do sleep 0.01; done
                    cat '\(d)/dry.json';;
                  *) while [ -f '\(d)/hold-land' ]; do sleep 0.01; done
                    [ -f '\(d)/fail-land' ] && { cat '\(d)/fail-land.json'; exit "$(cat '\(d)/fail-land')"; }
                    touch '\(d)/landed'
                    cat '\(d)/land.json';;
                esac;;
              "worktree update") cat '\(d)/worktree_update.json';;
              "worktree list") if [ -f '\(d)/landed' ]; then cat '\(d)/list-after.json'; else cat '\(d)/list.json'; fi;;
              *) exit 1;;
            esac
            """, at: dir.appendingPathComponent("loam"))
        let model = AppModel(client: LoamClient(binary: dir.appendingPathComponent("loam"), environment: [:]))
        model.shell = "/bin/zsh"
        model.apply([plot(plotID)])
        await model.reloadWorktrees()
        let record = LandRecord()
        model.onToast = { record.toasts.append(($0, $1)) }
        model.onOwnChange = { record.ownChanges.append($0) }
        model.confirmClose = { prompt in
            record.prompts.append(prompt)
            await poll { !record.holdsTheQuestion }
            return record.answer
        }
        let rig = Rig(dir: dir, model: model, record: record)
        try rig.plan()
        return rig
    }

    /// Opens the sheet and waits for the plan.
    @discardableResult
    func open(_ rig: Rig, _ id: String? = nil) async throws -> LandSheetContent {
        #expect(rig.model.openLandSheet(id ?? ready))
        await waitUntil("the plan came back") { rig.model.landSheet.plan != nil }
        return try #require(rig.model.landContent)
    }

    /// A pane that runs in the worktree. A shell pane has no session.
    @discardableResult
    func pane(in id: String, _ model: AppModel, _ kind: PaneSpec.Kind = .shell) throws -> PaneID {
        model.openWorktreePane(try #require(model.worktreeStatus(id)?.worktree), kind: kind)
        return try #require(model.workspace.focusedPane)
    }

    // MARK: Open and close

    @Test func openingReadsThePlanAndWhereItStandsOnce() async throws {
        let rig = try await rig()
        let model = rig.model
        #expect(!model.landSheet.isOpen)
        #expect(model.openLandSheet(ready))
        #expect(model.landSheet.isOpen && model.landSheet.worktreeID == ready)
        #expect(model.landSheet.phase == .loading, "the checklist shows a spinner until the plan is back")
        #expect(model.landContent == nil)
        await waitUntil("the plan came back") { model.landSheet.plan != nil }
        #expect(rig.dryRuns() == ["worktree land \(plotID) \(ready) --dry-run --json --actor app"])
        #expect(rig.calls("show") == ["show \(plotID) --json"])
        let content = try #require(model.landContent)
        #expect(content.title == "Land #22 Link labels" && content.canMerge)
        #expect(model.landSheet.whereText == "Merged #22 Link labels. Native panel spacing fails lint.")
        #expect(model.landSheet.whereSentence == "Merged #22 Link labels.")
        #expect(model.landSheet.whereVersion == 4)
        #expect(model.landSheet.removesWorktree && model.landSheet.deletesBranch && model.landSheet.movesWhereItStandsOn)
    }

    @Test func aWorktreeWithNoPullRequestOpensNoSheet() async throws {
        let rig = try await rig()
        #expect(!rig.model.openLandSheet(noPR))
        #expect(!rig.model.openLandSheet("nope"))
        #expect(!rig.model.landSheet.isOpen)
        #expect(!rig.args().isEmpty && rig.args().allSatisfy { $0.hasPrefix("worktree list") }, "only the list ran")
        #expect(rig.dryRuns().isEmpty && rig.lands().isEmpty)
    }

    @Test func openingClosesThePullRequestPopover() async throws {
        let rig = try await rig()
        rig.model.openPullRequest(ready)
        #expect(rig.model.prPopover.isOpen)
        rig.model.openLandSheet(ready)
        #expect(!rig.model.prPopover.isOpen && rig.model.landSheet.isOpen)
    }

    @Test func aDryRunThatFailsShowsItsMessage() async throws {
        let rig = try await rig()
        try rig.touch("fail-dry")
        rig.model.openLandSheet(ready)
        await waitUntil("the read failed") { if case .failed = rig.model.landSheet.phase { true } else { false } }
        guard case .failed(let message) = rig.model.landSheet.phase else { return }
        #expect(message.isEmpty == false)
        #expect(rig.model.landContent == nil)
        // With no plan there is nothing to merge.
        await rig.model.land()
        #expect(rig.lands().isEmpty)
        rig.model.closeLandSheet()
        #expect(!rig.model.landSheet.isOpen)
    }

    @Test func closingDropsAPlanThatComesLate() async throws {
        let rig = try await rig()
        try rig.touch("hold-dry")
        rig.model.openLandSheet(ready)
        rig.model.closeLandSheet()
        #expect(!rig.model.landSheet.isOpen)
        rig.remove("hold-dry")
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.model.landSheet.plan == nil && !rig.model.landSheet.isOpen)
    }

    @Test func aSecondOpenReplacesTheFirst() async throws {
        let rig = try await rig()
        try rig.touch("hold-dry")
        rig.model.openLandSheet(ready)
        rig.model.openLandSheet(failed)
        #expect(rig.model.landSheet.worktreeID == failed)
        rig.remove("hold-dry")
        await waitUntil("the plan came back") { rig.model.landSheet.plan != nil }
        #expect(rig.model.landSheet.worktreeID == failed)
    }

    @Test func theSheetClosesWhenItsWorktreeLeavesTheList() async throws {
        let rig = try await rig()
        try await open(rig)
        try rig.touch("landed")  // The next list lacks the worktree.
        await rig.model.reloadWorktrees()
        #expect(!rig.model.landSheet.isOpen)
    }

    // MARK: A check blocks

    /// The merge cannot be undone. Whatever the plan blocks on, and whatever the mode is, Merge runs nothing, closes
    /// no pane, and leaves the sheet open.
    @Test func mergeNeverRunsWhileACheckBlocks() async throws {
        let blockers: [(name: String, state: String)] = [
            ("checks", "failed"), ("review", "changes_requested"), ("behind_base", "behind"), ("conflicts", "conflicting"),
            ("github", "draft"), ("github", "blocked"), ("local_changes", "changed"), ("unpushed_commits", "unpushed"),
            ("local_changes", "unknown"),
        ]
        for blocker in blockers {
            for mode in ["direct", "queue", "running"] {
                let rig = try await rig()
                let model = rig.model
                let pane = try pane(in: ready, model)
                try rig.plan {
                    let index = $0.checks.firstIndex { $0.name == blocker.name }!
                    $0.checks[index] = LandCheck(name: blocker.name, state: blocker.state, blocks: true)
                    $0.changed = blocker.name == "local_changes" ? 2 : 0
                    $0.ready = false
                    if mode == "queue" { $0.mergeQueue = true }
                    if mode == "running" { $0.checks[0] = LandCheck(name: "checks", state: "running", blocks: blocker.name == "checks") }
                }
                try await open(rig)
                #expect(model.landContent?.canMerge == false, "\(blocker) \(mode)")
                await model.land()
                #expect(rig.lands().isEmpty, "the merge ran for \(blocker) in mode \(mode)")
                #expect(model.landSheet.isOpen && !model.landSheet.isMerging && model.landSheet.landError == nil)
                #expect(model.workspace.paneIDs(of: .plot(plotID)).contains(pane), "a pane closed for \(blocker)")
                #expect(rig.record.prompts.isEmpty && rig.record.toasts.isEmpty && rig.calls("set").isEmpty)
            }
        }
    }

    /// A plan whose `ready` says yes but whose rows say no is still not ready. The rows are what you read.
    @Test func mergeNeverRunsWhenARowBlocksButTheCoreSaidReady() async throws {
        let rig = try await rig()
        try rig.plan {
            $0.checks[1] = LandCheck(name: "review", state: "changes_requested", blocks: true)
            $0.ready = true
        }
        try await open(rig)
        await rig.model.land()
        #expect(rig.lands().isEmpty)
    }

    @Test func mergeNeverRunsForAPullRequestThatIsMergedAlready() async throws {
        let rig = try await rig()
        try rig.plan {
            $0.merged = true
            $0.pr.state = "MERGED"
            $0.checks = [LandCheck(name: "work_after_pr", state: "none", blocks: false)]
        }
        try await open(rig)
        #expect(rig.model.landContent?.canMerge == false)
        await rig.model.land()
        #expect(rig.lands().isEmpty)
    }

    @Test func aPlanThatBlocksKeepsTheSheetOpenForUpdateBranchAndSend() async throws {
        let rig = try await rig()
        try rig.plan {
            $0.stage = .checksFailed
            $0.checks[0] = LandCheck(name: "checks", state: "failed", blocks: true)
            $0.ready = false
        }
        let content = try await open(rig)
        #expect(content.rows.first?.action == .send(.failures))
        #expect(content.footer == "Fix the item in rust before you merge.")
    }

    // MARK: A merge now

    @Test func aMergeNowRunsLandWithTheMethodAndNoKeeps() async throws {
        let rig = try await rig()
        try await open(rig)
        await rig.model.land()
        #expect(rig.lands() == ["worktree land \(plotID) \(ready) --method squash --head \(head) --json --actor app"])
        #expect(rig.dryRuns().count == 1, "no second read for a land that went through")
    }

    @Test func theMethodThatYouChooseIsTheOneThatMerges() async throws {
        let rig = try await rig()
        try await open(rig)
        rig.model.landSheet.method = .rebase
        await rig.model.land()
        #expect(rig.lands().first?.contains("--method rebase") == true)
    }

    @Test func aMethodThatThePlanDoesNotAllowFallsBackToTheDefault() async throws {
        let rig = try await rig()
        try await open(rig)
        rig.model.landSheet.method = .merge  // The plan allows squash and rebase.
        await rig.model.land()
        #expect(rig.lands().first?.contains("--method squash") == true)
    }

    @Test func theBoxesThatYouUncheckBecomeKeeps() async throws {
        let rig = try await rig()
        try await open(rig)
        rig.model.landSheet.removesWorktree = false
        rig.model.landSheet.deletesBranch = false
        await rig.model.land()
        #expect(rig.lands() == ["worktree land \(plotID) \(ready) --method squash --keep-worktree --keep-remote-branch --head \(head) --json --actor app"])
    }

    @Test func keepingTheWorktreeClosesNoPane() async throws {
        let rig = try await rig()
        let pane = try pane(in: ready, rig.model)
        try await open(rig)
        rig.model.landSheet.removesWorktree = false
        await rig.model.land()
        #expect(rig.model.workspace.paneIDs(of: .plot(plotID)).contains(pane))
        #expect(rig.lands().count == 1 && rig.record.prompts.isEmpty)
    }

    @Test func theFirstBoxClosesThePanesOfTheWorktreeBeforeTheLand() async throws {
        let rig = try await rig()
        let model = rig.model
        let wt = try #require(model.worktreeStatus(ready)?.worktree)
        let first = try pane(in: ready, model)
        let second = try pane(in: ready, model)
        let other = try pane(in: failed, model)
        let record = rig.record
        model.paneClosesFinished = { record.panesAtFinish = model.landPanes(of: wt).count; record.landsAtFinish = rig.lands().count }
        let content = try await open(rig)
        #expect(content.removeLabel == "Close its 2 panes and remove the worktree")
        await model.land()
        let live = model.workspace.paneIDs(of: .plot(plotID))
        #expect(!live.contains(first) && !live.contains(second) && live.contains(other))
        #expect(record.panesAtFinish == 0 && record.landsAtFinish == 0, "the panes were gone before the land ran")
        let notOpen = try #require(model.worktreeStatus(failed)?.worktree.path)
        #expect(rig.lands() == ["worktree land \(plotID) \(ready) --method squash --head \(head) --open-pane \(notOpen) --json --actor app"],
                "the land names only the panes that stay")
        #expect(record.prompts.isEmpty, "a shell pane asks nothing")
    }

    @Test func aSessionInATurnAsksFirstAndCancelCancelsTheLand() async throws {
        let rig = try await rig()
        let model = rig.model
        let session = try pane(in: ready, model, .session)
        model.apply(paneEvent("SessionStart", model.workspace.session(of: session)?.sessionID ?? "", source: "startup"), to: session)
        model.apply(paneEvent("UserPromptSubmit", model.workspace.session(of: session)?.sessionID ?? ""), to: session)
        #expect(model.workspace.state(of: session) == .working)
        try await open(rig)
        rig.record.answer = false
        await model.land()
        let prompt = try #require(rig.record.prompts.first)
        #expect(prompt.title == "Close its panes and merge?" && prompt.confirm == "Close and merge")
        #expect(prompt.message == "1 session in this worktree is mid-turn. If you merge, the session stops and loses its partial reply.")
        #expect(rig.lands().isEmpty, "Cancel cancels the land")
        #expect(model.workspace.paneIDs(of: .plot(plotID)).contains(session), "Cancel closes no pane")
        #expect(model.landSheet.isOpen && !model.landSheet.isMerging && model.landSheet.landError == nil)
        // Confirm goes on.
        rig.record.answer = true
        await model.land()
        #expect(rig.record.prompts.count == 2)
        #expect(rig.lands().count == 1)
        #expect(!model.workspace.paneIDs(of: .plot(plotID)).contains(session))
    }

    @Test func aSessionThatNeedsYouAsksToo() async throws {
        let rig = try await rig()
        let model = rig.model
        let session = try pane(in: ready, model, .session)
        let id = model.workspace.session(of: session)?.sessionID ?? ""
        model.apply(paneEvent("SessionStart", id, source: "startup"), to: session)
        model.apply(paneEvent("PermissionRequest", id), to: session)
        #expect(model.workspace.state(of: session) == .needsYou)
        try await open(rig)
        await model.land()
        #expect(rig.record.prompts.first?.message == "1 session in this worktree needs you. If you merge, the session stops and loses its partial reply.")
    }

    @Test func anIdleSessionClosesWithNoQuestion() async throws {
        let rig = try await rig()
        let model = rig.model
        let session = try pane(in: ready, model, .session)
        model.apply(paneEvent("SessionStart", model.workspace.session(of: session)?.sessionID ?? "", source: "startup"), to: session)
        try await open(rig)
        await model.land()
        #expect(rig.record.prompts.isEmpty && rig.lands().count == 1)
        #expect(!model.workspace.paneIDs(of: .plot(plotID)).contains(session))
    }

    @Test func theSheetShowsMergingWhileTheLandRuns() async throws {
        let rig = try await rig()
        try await open(rig)
        try rig.touch("hold-land")
        let merge = Task { await rig.model.land() }
        await waitUntil("the land started") { !rig.lands().isEmpty }
        #expect(rig.model.landSheet.isMerging)
        rig.model.closeLandSheet()
        #expect(rig.model.landSheet.isOpen, "Cancel is off while the merge runs")
        #expect(!rig.model.openLandSheet(failed) && rig.model.landSheet.worktreeID == ready && rig.model.landSheet.isMerging,
                "an open of another worktree would drop the state of the merge")
        await rig.model.land()
        #expect(rig.lands().count == 1, "a second press runs nothing")
        rig.remove("hold-land")
        await merge.value
        #expect(!rig.model.landSheet.isOpen && !rig.model.landSheet.isMerging)
    }

    // MARK: A land that fails

    /// GitHub refuses the merge, such as for a branch rule. The sheet stays open, shows the message of GitHub, and
    /// you can press Merge again.
    @Test func aFailedLandLeavesTheSheetOpenWithTheMessageOfGitHub() async throws {
        let rig = try await rig()
        let model = rig.model
        let message = "could not merge PR #22: Pull request is not mergeable: the base branch policy prohibits the merge"
        try rig.failLand(code: 1, message: message)
        let pane = try pane(in: ready, model)
        try await open(rig)
        await model.land()
        #expect(rig.lands().count == 1)
        #expect(!model.workspace.allPaneIDs.contains(pane), "the pane closed before the land, as you asked")
        #expect(model.landSheet.isOpen && !model.landSheet.isMerging)
        #expect(model.landSheet.landError == message)
        #expect(rig.record.toasts.isEmpty, "a failed land says nothing in the toast")
        #expect(rig.calls("set").isEmpty, "Where it stands did not move on")
        #expect(model.worktreeStatus(ready) != nil, "the worktree stays")
        #expect(model.landSheet.plan != nil && model.landContent?.canMerge == true)
        // Press Merge again once GitHub allows it. There is no pane left to close.
        rig.remove("fail-land")
        await model.land()
        #expect(rig.lands().count == 2)
        #expect(!model.landSheet.isOpen)
        #expect(rig.record.toasts.map(\.text) == ["Merged #22. Removed the worktree link-labels."])
    }

    @Test func aFailedLandKeepsWhatYouTyped() async throws {
        let rig = try await rig()
        let model = rig.model
        try rig.failLand(code: 1, message: "could not merge PR #22: Head branch was modified")
        try await open(rig)
        model.landSheet.method = .rebase
        model.landSheet.deletesBranch = false
        model.landSheet.whereText = "Merged #22. My words."
        await model.land()
        #expect(model.landSheet.landError != nil)
        #expect(model.landSheet.method == .rebase && !model.landSheet.deletesBranch && model.landSheet.whereText == "Merged #22. My words.")
    }

    /// gh stops before GitHub answers (exit 1). GitHub may have the land, and the core says to land again. The sheet
    /// stays open with Merge on, and a second press runs the land again with the same commit.
    @Test func aLandThatGhStoppedCanBePressedAgain() async throws {
        let rig = try await rig()
        let model = rig.model
        let message = "gh stopped before GitHub answered, so GitHub may have the land of PR #22 (context deadline exceeded). "
            + "Run loam worktree land again to finish it"
        try rig.failLand(code: 1, message: message)
        try await open(rig)
        await model.land()
        #expect(model.landSheet.landError == message)
        #expect(model.landSheet.isOpen && !model.landSheet.isMerging && model.landContent?.canMerge == true)
        #expect(rig.dryRuns().count == 1, "only a block of the core reads the plan again")
        rig.remove("fail-land")
        await model.land()
        #expect(rig.lands().count == 2 && Set(rig.lands()).count == 1, "the same land, with the same commit")
        #expect(!model.landSheet.isOpen && rig.record.toasts.map(\.text) == ["Merged #22. Removed the worktree link-labels."])
    }

    @Test func theLandNamesTheCommitThatTheSheetShowedAndTheNewOneAfterAnUpdate() async throws {
        let rig = try await rig()
        try rig.plan {
            $0.pr.behindBase = 3
            $0.checks[2] = LandCheck(name: "behind_base", state: "behind", blocks: false)
        }
        try await open(rig)
        let updated = String(repeating: "4", count: 40)
        try rig.plan { $0.pr.headOID = updated }  // GitHub has a new head after the update.
        await rig.model.updateBranchFromLandSheet()
        await rig.model.land()
        #expect(rig.lands().count == 1 && rig.lands()[0].contains("--head \(updated)"), "\(rig.lands())")
    }

    /// The core stops a land whose PR has a commit that the sheet did not show (exit 16). The sheet reads the plan again.
    /// Until that plan is back, Merge is off, so the old plan cannot merge a PR that changed.
    @Test func theSheetStaysLockedUntilThePlanAfterABlockIsBack() async throws {
        let rig = try await rig()
        let model = rig.model
        try await open(rig)
        let message = "link-labels is not ready to land: PR #22 has new commits since you looked at it. Look again before you merge"
        try rig.failLand(code: 16, message: message)
        let newHead = String(repeating: "5", count: 40)
        try rig.plan { $0.pr.headOID = newHead }
        try rig.touch("hold-dry")
        let merge = Task { await model.land() }
        await waitUntil("the plan is read again") { rig.dryRuns().count == 2 && model.landSheet.landError != nil }
        #expect(model.landSheet.phase == .loading && model.landContent == nil, "the old plan is gone")
        #expect(!model.landSheet.isMerging, "Cancel works, but Merge does nothing")
        // Presses run in a task: a press that reached the land would wait for the held plan, and the test must fail, not hang.
        let presses = Task { await model.land(); await model.land() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.lands().count == 1, "no press merged while the new plan is out")
        rig.remove("hold-dry")
        await presses.value
        await merge.value
        await waitUntil("the new plan is back") { model.landSheet.plan != nil }
        #expect(model.landSheet.landError == message)
        #expect(model.landContent?.canMerge == true)
        rig.remove("fail-land")
        await model.land()
        #expect(rig.lands().count == 2 && rig.lands()[1].contains("--head \(newHead)"), "the second land names the new commit")
    }

    /// A plan that cannot be read after a block is not a plan to merge.
    @Test func aPlanThatCannotBeReadAfterABlockLeavesMergeOff() async throws {
        let rig = try await rig()
        let model = rig.model
        try await open(rig)
        try rig.failLand(code: 16, message: "link-labels is not ready to land: PR #22 has new commits since you looked at it")
        try rig.touch("fail-dry")
        await model.land()
        guard case .failed = model.landSheet.phase else {
            Issue.record("the phase is \(model.landSheet.phase)")
            return
        }
        await model.land()
        #expect(rig.lands().count == 1)
    }

    @Test func aWorktreeThatLeavesDuringAFailedMergeClosesTheSheet() async throws {
        let rig = try await rig()
        let model = rig.model
        try await open(rig)
        try rig.touch("hold-land")
        try rig.failLand(code: 1, message: "could not merge PR #22: Pull request is not mergeable")
        let merge = Task { await model.land() }
        await waitUntil("the land started") { !rig.lands().isEmpty }
        // Someone removed the worktree while the merge runs: the list loses it. The sheet stays while the merge runs.
        try rig.touch("landed")
        await model.reloadWorktrees()
        #expect(model.worktreeStatus(ready) == nil && model.landSheet.isOpen && model.landSheet.isMerging)
        rig.remove("hold-land")
        await merge.value
        #expect(!model.landSheet.isOpen, "a sheet for a worktree that is gone has nothing to merge")
    }

    // MARK: A merge that runs

    @Test func nothingElseOpensWhileAMergeRuns() async throws {
        let rig = try await rig()
        let model = rig.model
        try await open(rig)
        try rig.touch("hold-land")
        try rig.failLand(code: 1, message: "could not merge PR #22: nope")
        let merge = Task { await model.land() }
        await waitUntil("the land started") { !rig.lands().isEmpty }
        model.switcher.open()
        #expect(!model.switcher.isOpen, "the quick switcher stays shut: its commands would change the window under the merge")
        model.switcher.open(actionsOnly: true)
        #expect(!model.switcher.isOpen)
        // The PR popover would take the keys from the sheet, so a merge that fails would leave the sheet with no keys.
        #expect(!model.openPullRequest(ready), "Show Pull Request does nothing while a merge runs")
        #expect(!model.prPopover.isOpen)
        let selected = model.selectedWorktree
        #expect(!model.goToNextReadyWorktree(), "the key for the next ready worktree does nothing while a merge runs")
        #expect(!model.prPopover.isOpen && model.selectedWorktree == selected)
        #expect(model.landSheet.isOpen && model.landSheet.isMerging)
        rig.remove("hold-land")
        await merge.value
        // The merge failed, so the worktree is still there. Each one opens again, so the guard was the reason.
        #expect(model.landSheet.isOpen && !model.landSheet.isMerging)
        #expect(model.openPullRequest(ready))
        #expect(model.prPopover.isOpen)
        model.closePullRequest()
        #expect(model.goToNextReadyWorktree())
        model.switcher.open()
        #expect(model.switcher.isOpen)
    }

    /// What Quit needs to know when a merge ends: whether it failed. A failed merge leaves the sheet open with the message of
    /// GitHub, so Quit stops and the person reads it. Done, and cancelled with the question, let Quit go on.
    @Test func quitWaitsForAMergeThatRuns() async throws {
        let rig = try await rig()
        let model = rig.model
        var ends: [Bool] = []
        model.landSheet.whenMergeEnds { ends.append($0) }
        #expect(ends == [false], "with no merge, the answer is at once")
        try await open(rig)
        try rig.touch("hold-land")
        let merge = Task { await model.land() }
        await waitUntil("the land started") { !rig.lands().isEmpty }
        model.landSheet.whenMergeEnds { ends.append($0) }
        #expect(ends == [false], "the merge runs")
        rig.remove("hold-land")
        await merge.value
        #expect(ends == [false, false], "the merge is done")
        // A failed merge ends too, and says so. The list has the worktree again.
        rig.remove("landed")
        await model.reloadWorktrees()
        try await open(rig)
        try rig.failLand(code: 1, message: "could not merge PR #22: nope")
        try rig.touch("hold-land")
        let failing = Task { await model.land() }
        await waitUntil("the second land started") { rig.lands().count == 2 }
        model.landSheet.whenMergeEnds { ends.append($0) }
        #expect(ends == [false, false])
        rig.remove("hold-land")
        await failing.value
        #expect(ends == [false, false, true], "the merge failed")
        #expect(model.landSheet.isOpen && model.landSheet.landError != nil, "the sheet shows the message")
        // A merge that GitHub stopped with exit 16 failed too.
        try rig.failLand(code: 16, message: "link-labels is not ready to land: PR #22 has new commits since you looked at it")
        try rig.touch("hold-land")
        let stopped = Task { await model.land() }
        await waitUntil("the third land started") { rig.lands().count == 3 }
        model.landSheet.whenMergeEnds { ends.append($0) }
        rig.remove("hold-land")
        await stopped.value
        #expect(ends == [false, false, true, true])
        // The next merge starts from no failure.
        rig.remove("fail-land")
        try rig.touch("hold-land")
        let again = Task { await model.land() }
        await waitUntil("the fourth land started") { rig.lands().count == 4 }
        model.landSheet.whenMergeEnds { ends.append($0) }
        rig.remove("hold-land")
        await again.value
        #expect(ends == [false, false, true, true, false], "a merge that follows a failure is done, not failed")
    }

    /// Quit asks the app model, which waits for the merge and for a start. This is the merge side.
    @Test func quitWaitsForAMergeThroughTheAppModel() async throws {
        let rig = try await rig()
        let model = rig.model
        var ends: [Bool] = []
        model.whenSheetWorkEnds { ends.append($0) }
        #expect(ends == [false], "with no merge, the answer is at once")
        try await open(rig)
        try rig.failLand(code: 1, message: "could not merge PR #22: nope")
        try rig.touch("hold-land")
        let merge = Task { await model.land() }
        await waitUntil("the land started") { !rig.lands().isEmpty }
        model.whenSheetWorkEnds { ends.append($0) }
        #expect(ends == [false])
        rig.remove("hold-land")
        await merge.value
        #expect(ends == [false, true], "the merge failed, so Quit stops")
    }

    @Test func aLandQuestionThatYouCancelEndsTheMergeWithNoFailure() async throws {
        let rig = try await rig()
        let model = rig.model
        let session = try pane(in: ready, model, .session)
        model.apply(paneEvent("SessionStart", model.workspace.session(of: session)?.sessionID ?? "", source: "startup"), to: session)
        model.apply(paneEvent("UserPromptSubmit", model.workspace.session(of: session)?.sessionID ?? ""), to: session)
        try await open(rig)
        rig.record.answer = false
        rig.record.holdsTheQuestion = true
        let landing = Task { await model.land() }
        await waitUntil("the question shows") { !rig.record.prompts.isEmpty }
        #expect(model.landSheet.isMerging, "the sheet is locked while the question shows")
        var ends: [Bool] = []
        model.landSheet.whenMergeEnds { ends.append($0) }
        #expect(ends.isEmpty)
        rig.record.holdsTheQuestion = false
        await landing.value
        #expect(ends == [false], "Cancel is no failure, so a quit goes on")
        #expect(rig.lands().isEmpty && model.landSheet.landError == nil)
    }

    @Test func aBlockAtTheMergeReadsThePlanAgain() async throws {
        let rig = try await rig()
        let model = rig.model
        try await open(rig)
        // A review asked for changes after the sheet read the plan. The core exits 16 and the merge does not run.
        try rig.failLand(code: 16, message: "link-labels is not ready to land: a reviewer asked for changes")
        try rig.plan {
            $0.checks[1] = LandCheck(name: "review", state: "changes_requested", blocks: true)
            $0.ready = false
            $0.stage = .changesRequested
        }
        await model.land()
        #expect(model.landSheet.landError == "link-labels is not ready to land: a reviewer asked for changes")
        #expect(rig.dryRuns().count == 2, "the plan was read again")
        #expect(model.landContent?.canMerge == false)
        #expect(model.landContent?.rows.first { $0.id == "review" }?.tone == .blocking)
        #expect(model.landSheet.isOpen && !model.landSheet.isMerging && rig.record.toasts.isEmpty)
        await model.land()
        #expect(rig.lands().count == 1, "the second press found Merge off")
    }

    @Test func aGitHubThatIsNotAvailableShowsItsMessage() async throws {
        let rig = try await rig()
        let model = rig.model
        try await open(rig)
        try rig.failLand(code: 17, message: "gh is not signed in")
        await model.land()
        #expect(model.landSheet.landError == "gh is not signed in")
        #expect(model.landSheet.isOpen && rig.record.toasts.isEmpty)
    }

    // MARK: After the merge

    @Test func aMergeSavesWhereItStandsAsAChangeAndToasts() async throws {
        let rig = try await rig()
        let model = rig.model
        try await open(rig)
        model.landSheet.whereText = "Merged #22 Link labels. Next: land #24."
        await model.land()
        #expect(rig.calls("set") == ["set \(plotID) where-it-stands - --expect where=4 --json --actor app"])
        #expect(rig.read("set.stdin") == "Merged #22 Link labels. Next: land #24.")
        #expect(rig.record.ownChanges == [3], "the revision of the saved plot")
        #expect(rig.record.toasts.map(\.text) == ["Merged #22. Removed the worktree link-labels."])
        #expect(rig.record.toasts.first?.kind == .done)
        #expect(!model.landSheet.isOpen)
        #expect(model.worktreeStatus(ready) == nil, "the row left with the worktree")
    }

    @Test func theSavedTextIsTheTextOfTheBoxAfterYouEditIt() async throws {
        let rig = try await rig(whereText: "")
        try await open(rig)
        #expect(rig.model.landSheet.whereText == "Merged #22 Link labels.")
        await rig.model.land()
        #expect(rig.read("set.stdin") == "Merged #22 Link labels.")
    }

    @Test func theThirdBoxOffSavesNothing() async throws {
        let rig = try await rig()
        try await open(rig)
        rig.model.landSheet.movesWhereItStandsOn = false
        await rig.model.land()
        #expect(rig.calls("set").isEmpty && rig.record.ownChanges.isEmpty)
        #expect(rig.record.toasts.map(\.text) == ["Merged #22. Removed the worktree link-labels."])
    }

    @Test func aBoxThatYouEmptiedSavesNothing() async throws {
        let rig = try await rig()
        try await open(rig)
        rig.model.landSheet.whereText = " \n "
        await rig.model.land()
        #expect(rig.calls("set").isEmpty)
    }

    /// Someone else set Where it stands while the sheet was open. The save expects the old version, so it fails and
    /// loses nothing. The merge is done, so the sheet closes and the toast says what did not save.
    @Test func aWhereItStandsThatChangedMeanwhileIsNotOverwritten() async throws {
        let rig = try await rig()
        try rig.write("fail-set.json", Fixtures.data("error_stale"))
        try rig.touch("fail-set", "10")
        try await open(rig)
        await rig.model.land()
        #expect(rig.calls("set").count == 1 && rig.record.ownChanges.isEmpty)
        #expect(!rig.model.landSheet.isOpen)
        let toast = try #require(rig.record.toasts.first)
        #expect(toast.text == "Merged #22. Removed the worktree link-labels. Where it stands changed meanwhile, so Loam did not save it.")
        #expect(toast.kind == .notice)
    }

    @Test func aWhereItStandsThatFailsToSaveIsANotice() async throws {
        let rig = try await rig()
        try rig.write("fail-set.json", Fixtures.data("error_generic"))
        try rig.touch("fail-set", "1")
        try await open(rig)
        await rig.model.land()
        let toast = try #require(rig.record.toasts.first)
        #expect(toast.text.hasPrefix("Merged #22. Removed the worktree link-labels. Loam could not save Where it stands: "))
        #expect(toast.kind == .notice)
        #expect(!rig.model.landSheet.isOpen)
    }

    @Test func aWorktreeThatStaysShowsInTheToast() async throws {
        let rig = try await rig()
        var kept = try JSONDecoder().decode(LandResult.self, from: Fixtures.data("worktree_land"))
        kept.worktreeRemoved = false
        try rig.write("land.json", JSONEncoder().encode(kept))
        try await open(rig)
        rig.model.landSheet.removesWorktree = false
        await rig.model.land()
        #expect(rig.record.toasts.map(\.text) == ["Merged #22."], "a keep that you chose needs no word")
        #expect(rig.record.toasts.first?.kind == .done)
    }

    @Test func aKeepThatTheCoreMadeIsANotice() async throws {
        let rig = try await rig()
        var kept = try JSONDecoder().decode(LandResult.self, from: Fixtures.data("worktree_land"))
        kept.worktreeRemoved = false
        kept.worktreeNote = "Kept the worktree web-link-labels: it has 2 files with changes."
        try rig.write("land.json", JSONEncoder().encode(kept))
        try await open(rig)
        await rig.model.land()
        #expect(rig.record.toasts.map(\.text) == ["Merged #22. Loam kept the worktree link-labels."])
        #expect(rig.record.toasts.first?.kind == .notice)
    }

    // MARK: A merge that waits

    @Test func checksThatRunUseAutoAndCloseNoPane() async throws {
        let rig = try await rig()
        let pane = try pane(in: ready, rig.model)
        try rig.plan {
            $0.checks[0] = LandCheck(name: "checks", state: "running", blocks: false)
            $0.pr.checks = PRCheckCounts(state: "PENDING", total: 4, passed: 1, failed: 0, running: 3, waiting: 0)
        }
        var waiting = try JSONDecoder().decode(LandResult.self, from: Fixtures.data("worktree_land_auto"))
        waiting.pr.number = 22
        try rig.write("land.json", JSONEncoder().encode(waiting))
        let path = try #require(rig.model.worktreeStatus(ready)?.worktree.path)
        let content = try await open(rig)
        #expect(content.primaryTitle == "Merge when ready")
        await rig.model.land()
        #expect(rig.lands() == ["worktree land \(plotID) \(ready) --method squash --auto --head \(head) --open-pane \(path) --json --actor app"])
        #expect(rig.model.workspace.paneIDs(of: .plot(plotID)).contains(pane), "the tidy up comes later")
        #expect(rig.record.prompts.isEmpty)
        #expect(rig.record.toasts.map(\.text) == ["#22 will merge when its checks pass."])
        #expect(rig.calls("set").isEmpty, "Where it stands waits for the merge")
        #expect(!rig.model.landSheet.isOpen)
    }

    @Test func aMergeQueueTakesNoMethod() async throws {
        let rig = try await rig()
        try rig.plan {
            $0.mergeQueue = true
            $0.method = ""
        }
        var queued = try JSONDecoder().decode(LandResult.self, from: Fixtures.data("worktree_land_auto"))
        queued.auto = false
        queued.mergeQueue = true
        queued.pr.number = 22
        try rig.write("land.json", JSONEncoder().encode(queued))
        let content = try await open(rig)
        #expect(content.primaryTitle == "Add to merge queue")
        rig.model.landSheet.method = .rebase
        await rig.model.land()
        #expect(rig.lands().count == 1 && rig.lands().first?.contains("--method") == false)
        #expect(rig.lands().first?.contains("--auto") == false)
        #expect(rig.lands().first?.contains("--head \(head)") == true, "a merge queue gets the head of the plan too")
        #expect(rig.record.toasts.map(\.text) == ["Added #22 to the merge queue."])
    }

    // MARK: Rows

    @Test func updateBranchRunsTheCommandAndReadsThePlanAgain() async throws {
        let rig = try await rig()
        try rig.plan {
            $0.pr.behindBase = 3
            $0.checks[2] = LandCheck(name: "behind_base", state: "behind", blocks: false)
        }
        let content = try await open(rig)
        #expect(content.rows.first { $0.id == "behind_base" }?.action == .updateBranch)
        #expect(content.canMerge, "behind base does not block")
        try rig.plan()  // After the update the branch is up to date.
        await rig.model.updateBranchFromLandSheet()
        #expect(rig.calls("worktree update") == ["worktree update \(plotID) \(ready) --json --actor app"])
        #expect(rig.dryRuns().count == 2)
        #expect(rig.model.landContent?.rows.first { $0.id == "behind_base" }?.title == "Up to date with main")
        #expect(!rig.model.landSheet.isUpdating)
    }

    @Test func sendToSessionClosesTheSheetAndTypesThePrompt() async throws {
        let rig = try await rig()
        let model = rig.model
        var typed: [String] = []
        model.typeIntoPane = { _, text in typed.append(text); return true }
        let session = try pane(in: failed, model, .session)
        model.apply(paneEvent("SessionStart", model.workspace.session(of: session)?.sessionID ?? "", source: "startup"), to: session)
        // The row of native-panel is Checks failed. The plan agrees with it.
        var plan = try JSONDecoder().decode(LandResult.self, from: Fixtures.data("worktree_land_dry_run"))
        plan.worktree = try #require(model.worktreeStatus(failed)?.worktree)
        plan.pr = try #require(model.worktreeStatus(failed)?.pr)
        plan.stage = .checksFailed
        plan.checks[0] = LandCheck(name: "checks", state: "failed", blocks: true)
        plan.ready = false
        try rig.write("dry.json", JSONEncoder().encode(plan))
        let content = try await open(rig, failed)
        #expect(content.rows.first?.action == .send(.failures))
        await model.sendFromLandSheet(.failures)
        #expect(!model.landSheet.isOpen)
        #expect(typed.count == 1 && typed[0].hasPrefix("Checks failed on #16"))
        #expect(rig.lands().isEmpty)
    }

    @Test func aSendThatDoesNotMatchTheRowSaysSo() async throws {
        let rig = try await rig()
        try await open(rig)  // The row is Ready to merge, which has no prompt.
        await rig.model.sendFromLandSheet(.failures)
        #expect(rig.model.landSheet.isOpen)
        #expect(rig.model.landSheet.landError == "The pull request changed since the sheet read it. Close the sheet and open it again.")
    }
}
