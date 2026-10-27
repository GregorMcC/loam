import Foundation
import Testing
@testable import LoamKit

/// Reads `contract/fixtures/` by a path relative to this file. No Go needed.
enum Fixtures {
    struct Entry: Decodable {
        var name: String
        var args: [String]
        var exitCode: Int32
        var schema: String
        enum CodingKeys: String, CodingKey { case name, args, exitCode = "exit_code", schema }
    }

    static let dir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // LoamKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // app
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("contract/fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent("\(name).json"))
    }

    static func manifest() throws -> [Entry] {
        try JSONDecoder().decode([Entry].self, from: data("manifest"))
    }
}

/// Decodes a fixture by its schema name. Every schema in the manifest needs a case here.
func decodeFixture(schema: String, data: Data) throws {
    let d = JSONDecoder()
    switch schema {
    case "version": _ = try d.decode(VersionInfo.self, from: data)
    case "list": _ = try d.decode([PlotSummary].self, from: data)
    case "show", "new", "set", "edit": _ = try d.decode(Plot.self, from: data)
    case "link-add", "link-edit", "link-rm", "repo-add", "repo-edit", "repo-main", "repo-rm":
        _ = try d.decode(WriteResult.self, from: data)
    case "sessions": _ = try d.decode([SessionRecord].self, from: data)
    case "move": _ = try d.decode(MoveResult.self, from: data)
    case "open": _ = try d.decode(OpenResult.self, from: data)
    case "pane-event": _ = try d.decode(PaneEvent.self, from: data)
    case "export": _ = try d.decode(ExportResponse.self, from: data)
    case "setup-check": _ = try d.decode(SetupCheck.self, from: data)
    case "changes": _ = try d.decode(ChangesResponse.self, from: data)
    case "undo": _ = try d.decode(UndoResult.self, from: data)
    case "worktree-new": _ = try d.decode(WorktreeNewResult.self, from: data)
    case "worktree-new-dry-run": _ = try d.decode(WorktreeCheck.self, from: data)
    case "worktree-edit": _ = try d.decode(WorktreeEditResult.self, from: data)
    case "worktree-list": _ = try d.decode([WorktreeStatus].self, from: data)
    case "worktree-rm": _ = try d.decode(WorktreeRmResult.self, from: data)
    case "worktree-land": _ = try d.decode(LandResult.self, from: data)
    case "worktree-rerun": _ = try d.decode(RerunResult.self, from: data)
    case "worktree-update": _ = try d.decode(UpdateResult.self, from: data)
    case "delete": _ = try d.decode(DeleteResult.self, from: data)
    case "run-start": _ = try d.decode(RunStartResult.self, from: data)
    case "run-list": _ = try d.decode([Run].self, from: data)
    case "run-status": _ = try d.decode(RunStatus.self, from: data)
    case "run-stop", "run-send-back", "run-shape": _ = try d.decode(RunResult.self, from: data)
    case "run-land": _ = try d.decode(RunLandResult.self, from: data)
    case "run-diff": _ = try d.decode(RunDiff.self, from: data)
    case "run-tick": _ = try d.decode(RunTickResult.self, from: data)
    case "recurring": _ = try d.decode(RecurringOne.self, from: data)
    case "recurring-list": _ = try d.decode(RecurringList.self, from: data)
    case "recurring-run": _ = try d.decode(RecurringResult.self, from: data)
    case "tick": _ = try d.decode(TickResult.self, from: data)
    case "tick-status": _ = try d.decode(TickStatus.self, from: data)
    case "intake-list": _ = try d.decode(IntakeList.self, from: data)
    case "linear-status", "linear-key": _ = try d.decode(LinearStatus.self, from: data)
    default: Issue.record("No Swift type for schema \(schema)")
    }
}

@Suite struct FixtureTests {
    /// Ticket 207: a line on one side of a diff has no number on the other.
    @Test func aRunDiffDecodesItsLines() throws {
        let diff = try JSONDecoder().decode(RunDiff.self, from: Fixtures.data("run_diff"))
        let file = try #require(diff.files.first)
        #expect(file.path == "README.md" && file.status == "modified" && file.added == 3 && file.oldPath == nil)
        let lines = try #require(file.hunks.first?.lines)
        #expect(lines.first == RunDiff.Line(kind: .del, old: 1, new: nil, text: "hello"))
        #expect(lines[1] == RunDiff.Line(kind: .add, old: nil, new: 1, text: "# Loam"))
    }

    /// Ticket 207: a Shaping run has the rest of Claude's draft in its shape.
    @Test func aShapingRunDecodesItsDraft() throws {
        let run = try JSONDecoder().decode(RunResult.self, from: Fixtures.data("run_shape")).run
        #expect(run.state == .shaping && run.worktreeID.isEmpty)
        let shape = try #require(run.shape)
        #expect(shape.assumptions == [RunAssumption(text: "The plan shows as a numbered list.", answer: "")])
        #expect(shape.plan.count == 2 && shape.size == "About 60 lines in the app." && shape.isDrafted)
        let approved = try JSONDecoder().decode(RunStartResult.self, from: Fixtures.data("run_approve")).run
        #expect(approved.shape?.assumptions.first?.answer == "The plan shows as steps with checkboxes.")
    }

    @Test func aRecurringRunAndATickDecode() throws {
        let added = try JSONDecoder().decode(RecurringOne.self, from: Fixtures.data("recurring_add")).recurring
        #expect(added.kind == .chore && added.days.count == 7 && added.at == "02:00" && added.precheck == "false")
        #expect(added.ifAsleep == .once && added.doneWhen.count == 1 && added.lastAt == nil && !added.nextAt.isEmpty)
        let list = try JSONDecoder().decode(RecurringList.self, from: Fixtures.data("recurring_list")).recurring
        #expect(list.map(\.title) == ["Bump Go dependencies", "Shape new issues"])
        #expect(list[1].ifAsleep == .skip && list[1].lastRunID.isEmpty == false)
        let tick = try JSONDecoder().decode(TickResult.self, from: Fixtures.data("tick"))
        #expect(tick.recurring.map(\.run?.state) == [.skipped, nil])
        #expect(tick.recurring[0].note.contains("found no work") && tick.runs.isEmpty)
        let status = try JSONDecoder().decode(TickStatus.self, from: Fixtures.data("tick_install"))
        #expect(status.installed && status.interval == 300 && status.lastTick?.error == "")
        #expect(try JSONDecoder().decode(TickStatus.self, from: Fixtures.data("tick_uninstall")).installed == false)
    }

    @Test func everyFixtureDecodes() throws {
        let entries = try Fixtures.manifest()
        #expect(entries.count >= 39)
        for e in entries {
            let data = try Fixtures.data(e.name)
            if e.exitCode == 0 {
                try decodeFixture(schema: e.schema, data: data)
            } else {
                let env = try JSONDecoder().decode(ErrorEnvelope.self, from: data)
                #expect(env.error.exitCode == Int(e.exitCode), "\(e.name)")
            }
        }
    }

    @Test func noFixtureFileIsLeftOut() throws {
        let listed = Set(try Fixtures.manifest().map(\.name) + ["manifest"])
        let files = try FileManager.default.contentsOfDirectory(atPath: Fixtures.dir.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
        #expect(Set(files) == listed)
    }

    @Test func nullsAndMissingKeysDecode() throws {
        let changes = try JSONDecoder().decode(ChangesResponse.self, from: Fixtures.data("changes"))
        #expect(changes.changes[0].entries[0].old == nil)
        #expect(changes.changes[0].entries[0].new == "Loam")
        #expect(changes.changes[0].undoOf == nil)
        #expect(changes.changes[0].actor.kind == .cli)
        #expect(changes.changes[0].actor.sessionID == nil)
        let plot = try JSONDecoder().decode(Plot.self, from: Fixtures.data("show_full"))
        #expect(plot.whereItStands == "Building.")
        #expect(plot.versions["where"] == 4)
        #expect(plot.repos[0].main)
    }

    /// Ticket 113: each repo says what the app does after a merge on GitHub. A value that the app does not know, and
    /// a core with no setting, read as Ask, so they never remove a worktree.
    @Test func theRepoSettingAfterAMergeDecodes() throws {
        let plot = try JSONDecoder().decode(Plot.self, from: Fixtures.data("show_full"))
        #expect(plot.repos[0].afterMerge == .ask)
        func repo(_ extra: String) throws -> Repo {
            try JSONDecoder().decode(Repo.self, from: Data(#"{"id":"repoaaaaaa","path":"/tmp/web","note":"","main":true,"version":1\#(extra)}"#.utf8))
        }
        #expect(try repo(#","after_merge":"remove""#).afterMerge == .remove)
        #expect(try repo(#","after_merge":"keep""#).afterMerge == .keep)
        #expect(try repo(#","after_merge":"archive""#).afterMerge == .ask)
        #expect(try repo("").afterMerge == nil)
    }

    @Test func setupCheckDrivesTheBanner() throws {
        let check = try JSONDecoder().decode(SetupCheck.self, from: Fixtures.data("setup_check"))
        #expect(check.needsBanner)
        #expect(check.pendingSteps.map(\.id) == ["mcp"])
        #expect(check.pendingSteps[0].detail != nil)
    }

    @Test func linkPathMissingCarriesItsDetails() throws {
        let env = try JSONDecoder().decode(ErrorEnvelope.self, from: Fixtures.data("error_link_path_missing"))
        let error = LoamError.from(exitCode: 12, message: env.error.message, details: env.error.details?.data)
        guard case .linkPathMissing(let details, _) = error else {
            Issue.record("wrong case: \(error)")
            return
        }
        #expect(details?.plotID == "plotaaaaab")
        #expect(details?.linkID == "linkaaaaai")
        #expect(details?.path == "/tmp/loam-contract/vault/missing.md")
    }

    @Test func newFieldsDecode() throws {
        let open = try JSONDecoder().decode(OpenResult.self, from: Fixtures.data("open_vault"))
        #expect(open.kind == .vault)
        #expect(open.openedWith == .obsidian)
        let plot = try JSONDecoder().decode(Plot.self, from: Fixtures.data("show_links"))
        #expect(plot.links.contains { $0.exists != nil })
        let wt = try JSONDecoder().decode([WorktreeStatus].self, from: Fixtures.data("worktree_list"))
        #expect(wt[0].mergedInto == "origin/main")
        let rm = try JSONDecoder().decode(WorktreeRmResult.self, from: Fixtures.data("worktree_rm"))
        #expect(rm.branchNote == nil)
        let del = try JSONDecoder().decode(DeleteResult.self, from: Fixtures.data("delete"))
        #expect(del.claudeFiles.count == 1)
    }

    @Test func worktreeGoalDecodes() throws {
        let made = try JSONDecoder().decode(WorktreeNewResult.self, from: Fixtures.data("worktree_new"))
        #expect(made.worktree.goal == "Fix the login form")
        // The origin of the fixture repo is not on GitHub, so the key names the repo.
        #expect(made.worktree.link?.key == "example/widgets#57")
        #expect(made.worktree.link?.linkID == "")
        #expect(made.worktree.version == 0)
        let check = try JSONDecoder().decode(WorktreeCheck.self, from: Fixtures.data("worktree_new_dry_run"))
        #expect(check.validName)
        #expect(check.nameError == nil)
        #expect(check.defaultBase == "origin/main")
        #expect(check.bases.first == "origin/main")
        let edit = try JSONDecoder().decode(WorktreeEditResult.self, from: Fixtures.data("worktree_edit"))
        #expect(edit.changeID > 0)
        #expect(edit.worktree.version == edit.changeID)
        #expect(edit.worktree.link == nil)
        // A stale goal edit carries the current worktree.
        let env = try JSONDecoder().decode(ErrorEnvelope.self, from: Fixtures.data("error_stale_worktree"))
        guard case .stale(let details, _) = LoamError.from(exitCode: 10, message: env.error.message, details: env.error.details?.data) else {
            Issue.record("not a stale error")
            return
        }
        #expect(details?.items.first?.worktree?.goal == "Fix the login form on phones")
    }

    @Test func prStateDecodes() throws {
        let plain = try JSONDecoder().decode([WorktreeStatus].self, from: Fixtures.data("worktree_list"))
        #expect(plain[0].stage == .noStage)
        #expect(plain[0].pr == nil)
        #expect(plain[0].prNote == .noNote)
        #expect(plain[0].prCheckedAt == nil)

        // One worktree for each stage, in the order of the rule, then a
        // second Ready to merge whose optional checks failed.
        let list = try JSONDecoder().decode([WorktreeStatus].self, from: Fixtures.data("worktree_list_stages"))
        let stages = WorktreeStage.allCases.filter { $0 != .noStage }
        #expect(stages.count == 15)
        #expect(list.count == stages.count + 1)
        #expect(list.prefix(stages.count).map(\.stage) == stages)
        #expect(list.allSatisfy { $0.prCheckedAt != nil && $0.prNote == .noNote })
        let merged = try #require(list.first { $0.stage == .merged }?.pr)
        #expect(merged.mergedAt != nil)
        #expect(list.first { $0.stage == .inMergeQueue }?.pr?.queuePosition == 2)
        let failed = try #require(list.first { $0.stage == .checksFailed }?.pr)
        #expect(failed.checks.failed == 2)
        #expect(failed.failedChecks.map(\.name) == ["lint / swiftformat", "test / macos"])
        #expect(failed.failedChecks[0].duration == 42 && failed.failedChecks[0].required)
        #expect(failed.checks.required == 3 && failed.checks.requiredPassed == 1)
        // The passed checks have the fields of a failed check, in the order of GitHub (ticket 116).
        #expect(failed.passedChecks?.map(\.name) == ["build"])
        #expect(failed.passedChecks?.first?.duration == 80 && failed.passedChecks?.first?.required == true)
        #expect(failed.passedChecks?.first?.url == "https://github.com/example/widgets/actions/runs/300/job/0")
        #expect(list.first { $0.stage == .merged }?.pr?.passedChecks == [])
        #expect(list.first { $0.stage == .blocked }?.pr?.mergeState == "BLOCKED")
        // "2 of 2 required checks passed · 2 optional failed"
        let unstable = try #require(list.last)
        #expect(unstable.stage == .readyToMerge)
        let optional = try #require(unstable.pr)
        #expect(optional.mergeState == "UNSTABLE")
        #expect(optional.checks.required == 2 && optional.checks.requiredPassed == 2)
        #expect(optional.checks.failed == 2 && optional.failedChecks.allSatisfy { !$0.required })
        #expect(optional.passedChecks?.map(\.name) == ["build", "test"])
        #expect(optional.passedChecks?.count == optional.checks.passed)
        let pushed = try #require(list.first { $0.stage == .pushedNoPR })
        #expect(pushed.pr == nil)
        #expect(pushed.compareURL == "https://github.com/example/widgets/compare/main...pushed-only")
    }

    /// A core from before ticket 116 sends no `passed_checks`. The list still decodes, as it did before.
    @Test func aPRFromAnOlderCoreHasNoPassedChecks() throws {
        var list = try #require(JSONSerialization.jsonObject(with: Fixtures.data("worktree_list_stages")) as? [[String: Any]])
        for index in list.indices {
            guard var pr = list[index]["pr"] as? [String: Any] else { continue }
            pr["passed_checks"] = nil
            list[index]["pr"] = pr
        }
        let decoded = try JSONDecoder().decode([WorktreeStatus].self, from: JSONSerialization.data(withJSONObject: list))
        let prs = decoded.compactMap(\.pr)
        #expect(!prs.isEmpty && prs.allSatisfy { $0.passedChecks == nil })
    }

    @Test func landRerunAndUpdateDecode() throws {
        let d = JSONDecoder()
        let plan = try d.decode(LandResult.self, from: Fixtures.data("worktree_land_dry_run"))
        #expect(plan.dryRun && plan.ready && !plan.merged)
        #expect(plan.methods == ["squash", "rebase"] && plan.defaultMethod == "squash")
        #expect(plan.checks.map(\.name) == ["checks", "review", "behind_base", "conflicts", "github", "local_changes", "unpushed_commits"])
        let blocked = try d.decode(LandResult.self, from: Fixtures.data("worktree_land_dry_run_blocked"))
        #expect(!blocked.ready)
        #expect(blocked.checks.filter(\.blocks) == [LandCheck(name: "review", state: "changes_requested", blocks: true)])
        let land = try d.decode(LandResult.self, from: Fixtures.data("worktree_land"))
        #expect(land.merged && land.method == "rebase" && land.remoteBranchDeleted && land.worktreeRemoved)
        #expect(land.branchNote == nil && land.worktree.land == nil && land.landNote == nil)
        // A land that cleared a stale land of another PR says so in land_note.
        var withNote = try #require(JSONSerialization.jsonObject(with: Fixtures.data("worktree_land")) as? [String: Any])
        withNote["land_note"] = "Loam cleared the land of PR #12 that the worktree recorded: the branch has PR #23 now."
        let stale = try d.decode(LandResult.self, from: JSONSerialization.data(withJSONObject: withNote))
        #expect(stale.landNote?.hasPrefix("Loam cleared the land of PR #12") == true)
        let auto = try d.decode(LandResult.self, from: Fixtures.data("worktree_land_auto"))
        #expect(auto.mergeLater && !auto.worktreeRemoved)
        #expect(auto.worktree.land == PendingLand(pr: 23, method: "squash", auto: true, mergeQueue: false,
                                                  keepWorktree: false, keepRemoteBranch: false))
        let rerun = try d.decode(RerunResult.self, from: Fixtures.data("worktree_rerun"))
        #expect(rerun.runs.map(\.id) == [301, 302] && rerun.runs.map(\.started) == [true, false])
        #expect(rerun.runs[0].note == nil && rerun.runs[1].note?.contains("could not re-run the run 302") == true)
        #expect(rerun.skippedChecks.isEmpty)
        let update = try d.decode(UpdateResult.self, from: Fixtures.data("worktree_update"))
        #expect(update.fetched && update.fetchNote == nil)
        let list = try d.decode([WorktreeStatus].self, from: Fixtures.data("worktree_list_stages"))
        let failed = try #require(list.first { $0.stage == .checksFailed }?.pr)
        #expect(failed.failedChecks.map(\.runID) == [301, 302])
    }

    /// Ticket 113: a refused `loam worktree rm` carries what it refused, so the app words it.
    @Test func aRefusedRemovalCarriesItsDetails() throws {
        func error(_ fixture: String) throws -> LoamError {
            let env = try JSONDecoder().decode(ErrorEnvelope.self, from: Fixtures.data(fixture))
            return LoamError.from(exitCode: 1, message: env.error.message, details: env.error.details?.data)
        }
        guard case .refusedRemoval(let unsafe, let message) = try error("error_worktree_rm_unsafe") else {
            Issue.record("not a refused removal")
            return
        }
        #expect(unsafe == RemovalRefusal(refusal: .unsafeWork, changed: 1))
        #expect(message.contains("--force"), "the message of the core names the flag that the app words away")
        guard case .refusedRemoval(let panes, _) = try error("error_worktree_rm_panes_open") else {
            Issue.record("not a refused removal")
            return
        }
        #expect(panes == RemovalRefusal(refusal: .openPanes, openPanes: 1))
        guard case .failed = try error("error_generic") else {
            Issue.record("an error with no details is not .failed")
            return
        }
    }

    @Test func notReadyCarriesTheBlockingChecks() throws {
        let env = try JSONDecoder().decode(ErrorEnvelope.self, from: Fixtures.data("error_not_ready"))
        let error = LoamError.from(exitCode: 16, message: env.error.message, details: env.error.details?.data)
        guard case .notReady(let details, _) = error else {
            Issue.record("wrong case: \(error)")
            return
        }
        #expect(details?.checks == [LandCheck(name: "conflicts", state: "conflicting", blocks: true)])
    }

    @Test func aDraftBlocksTheLand() throws {
        let env = try JSONDecoder().decode(ErrorEnvelope.self, from: Fixtures.data("error_not_ready_draft"))
        let error = LoamError.from(exitCode: 16, message: env.error.message, details: env.error.details?.data)
        guard case .notReady(let details, _) = error else {
            Issue.record("wrong case: \(error)")
            return
        }
        #expect(details?.checks == [LandCheck(name: "github", state: "draft", blocks: true)])
    }

    /// A land that names a PR head that GitHub no longer has: exit 16 with no check that blocks.
    @Test func aNewCommitStopsTheLandWithNoBlockingCheck() throws {
        let env = try JSONDecoder().decode(ErrorEnvelope.self, from: Fixtures.data("error_not_ready_head"))
        let error = LoamError.from(exitCode: 16, message: env.error.message, details: env.error.details?.data)
        guard case .notReady(let details, let message) = error else {
            Issue.record("wrong case: \(error)")
            return
        }
        #expect(details?.checks == [])
        #expect(message.contains("has new commits since you looked at it. Look again before you merge"))
        #expect(error.userMessage == message)
    }

    @Test func theNewStageAndNoteDecode() throws {
        let json = Data(#""blocked""#.utf8)
        #expect(try JSONDecoder().decode(WorktreeStage.self, from: json) == .blocked)
        #expect(try JSONDecoder().decode(PRNote.self, from: Data(#""no_access""#.utf8)) == .noAccess)
    }

    @Test func anUnknownStageOrNoteDecodesAsNothing() throws {
        let json = Data(#"[{"stage": "some_new_stage", "pr_note": "some_new_note"}]"#.utf8)
        struct Row: Decodable {
            var stage: WorktreeStage
            var prNote: PRNote
            enum CodingKeys: String, CodingKey { case stage, prNote = "pr_note" }
        }
        let rows = try JSONDecoder().decode([Row].self, from: json)
        #expect(rows[0].stage == .noStage)
        #expect(rows[0].prNote == .noNote)
    }
}
