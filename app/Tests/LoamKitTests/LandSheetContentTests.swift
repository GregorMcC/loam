import Foundation
import Testing

@testable import LoamKit

/// Ticket 112: what the Land sheet says for a dry run of `loam worktree land`. The plans come from the
/// `worktree_land_dry_run` fixture (made-up example/widgets data), which has every check clear. Each test changes the
/// fields that its state needs. The content is a pure value, so no window or `loam` runs here.
@Suite struct LandSheetContentTests {
    /// The ready plan: PR 22 "Link labels", 9 commits, one passed check, one approval, squash and rebase allowed.
    func ready() throws -> LandResult {
        try JSONDecoder().decode(LandResult.self, from: Fixtures.data("worktree_land_dry_run"))
    }

    /// A plan where `name` is in `state`, and blocks as `blocks` says.
    func with(_ name: String, _ state: String, blocks: Bool = false, edit: (inout LandResult) -> Void = { _ in }) throws -> LandResult {
        var plan = try ready()
        let index = try #require(plan.checks.firstIndex { $0.name == name })
        plan.checks[index] = LandCheck(name: name, state: state, blocks: blocks)
        plan.ready = !plan.checks.contains(where: \.blocks)
        edit(&plan)
        return plan
    }

    func sheet(_ plan: LandResult, panes: Int = 0) -> LandSheetContent { LandSheetContent(plan, openPanes: panes) }

    func row(_ content: LandSheetContent, _ id: String) throws -> LandSheetContent.Row {
        try #require(content.rows.first { $0.id == id })
    }

    // MARK: A ready worktree

    @Test func aReadyPlanListsFiveRowsAndMerges() throws {
        let content = sheet(try ready())
        #expect(content.title == "Land #22 Link labels")
        #expect(content.subtitle == "link-labels \u{2192} main \u{00B7} 9 commits")
        #expect(content.rows.map(\.id) == ["checks", "review", "behind_base", "conflicts", "worktree"])
        #expect(content.rows.map(\.title) == ["Checks pass", "Review approved", "Up to date with main", "No conflicts", "Worktree saved and pushed"])
        #expect(content.rows.map(\.value) == ["1 of 1", "1 approval", "0 behind", "", "0 changed \u{00B7} 0 not pushed"])
        #expect(content.rows.allSatisfy { $0.tone == .good && $0.action == nil && $0.hint == nil })
        #expect(content.primary == .merge && content.primaryTitle == "Merge #22" && content.canMerge)
        #expect(content.footer == "You cannot undo a merge.")
        #expect(content.blockingCount == 0)
        #expect(content.mergeMethods == [.squash, .rebase] && content.defaultMethod == .squash)
        #expect(!content.usesAuto && !content.mergeQueue)
    }

    @Test func theMethodsAreOnlyThoseTheRepoAllows() throws {
        var plan = try ready()
        plan.methods = ["merge", "squash", "rebase"]
        plan.defaultMethod = "merge"
        #expect(sheet(plan).mergeMethods == [.merge, .squash, .rebase])
        #expect(sheet(plan).defaultMethod == .merge)
        plan.methods = ["rebase", "new-method-of-a-later-core"]
        plan.defaultMethod = "new-method-of-a-later-core"
        #expect(sheet(plan).mergeMethods == [.rebase])
        #expect(sheet(plan).defaultMethod == .rebase)  // The first method it knows, when the default is unknown.
    }

    @Test func methodNamesAreForAPerson() {
        #expect(MergeMethod.merge.title == "Merge commit")
        #expect(MergeMethod.squash.title == "Squash")
        #expect(MergeMethod.rebase.title == "Rebase")
    }

    @Test func aReviewThatIsNotRequiredAndNoChecksSayWhatTheyAre() throws {
        var plan = try with("review", "none")
        plan.checks[0] = LandCheck(name: "checks", state: "none", blocks: false)
        let content = sheet(plan)
        #expect(try row(content, "checks").title == "No checks")
        #expect(try row(content, "review").title == "No review required")
        #expect(content.canMerge)
    }

    @Test func oneApprovalAndManyApprovalsUseTheRightNumber() throws {
        var plan = try ready()
        plan.pr.approvals = 2
        #expect(try row(sheet(plan), "review").value == "2 approvals")
        plan.pr.approvals = 0
        #expect(try row(sheet(plan), "review").value == "")
    }

    // MARK: A check blocks

    @Test func failedChecksBlockAndOfferSendFailures() throws {
        let plan = try with("checks", "failed", blocks: true) {
            $0.stage = .checksFailed
            $0.pr.checks = PRCheckCounts(state: "FAILURE", total: 14, passed: 12, failed: 2, running: 0, waiting: 0)
        }
        let content = sheet(plan)
        let checks = try row(content, "checks")
        #expect(checks.title == "Checks fail" && checks.value == "2 of 14" && checks.tone == .blocking)
        #expect(checks.action == .send(.failures) && checks.hint == nil)
        #expect(!content.canMerge && content.blockingCount == 1)
        #expect(content.footer == "Fix the item in rust before you merge.")
    }

    @Test func aFailureThatAnotherStageHidesGetsAHintNotAButton() throws {
        // Changes requested comes before checks failed in the stage order, so a session would get the review prompt.
        let plan = try with("checks", "failed", blocks: true) { $0.stage = .changesRequested }
        let checks = try row(sheet(plan), "checks")
        #expect(checks.action == nil && checks.hint == "Fix the failed checks")
    }

    @Test func changesRequestedBlocksAndOffersSendReview() throws {
        let blocked = try JSONDecoder().decode(LandResult.self, from: Fixtures.data("worktree_land_dry_run_blocked"))
        let content = sheet(blocked)
        let review = try row(content, "review")
        #expect(review.title == "Changes requested" && review.tone == .blocking)
        #expect(review.value == "\(blocked.pr.comments) \(blocked.pr.comments == 1 ? "comment" : "comments")")
        #expect(review.action == .send(.review))
        #expect(!content.canMerge && content.blockingCount == 1)
    }

    @Test func conflictsBlockAndOfferSendConflicts() throws {
        let plan = try with("conflicts", "conflicting", blocks: true) { $0.stage = .conflicts }
        let conflicts = try row(sheet(plan), "conflicts")
        #expect(conflicts.title == "Conflicts with main" && conflicts.tone == .blocking && conflicts.action == .send(.conflicts))
        #expect(!sheet(plan).canMerge)
    }

    @Test func conflictsThatGitHubStillChecksDoNotBlock() throws {
        let conflicts = try row(sheet(try with("conflicts", "checking")), "conflicts")
        #expect(conflicts.title == "Checking for conflicts" && conflicts.tone == .note)
        #expect(sheet(try with("conflicts", "checking")).canMerge)
    }

    @Test func workInTheWorktreeBlocksWithAHintForEachKind() throws {
        func local(changed: Int, unpushed: Int, unknown: Bool = false) throws -> LandSheetContent.Row {
            var plan = try ready()
            plan.changed = changed
            plan.unpushed = unpushed
            let (c, u) = unknown ? ("unknown", "unknown") : (changed > 0 ? "changed" : "none", unpushed > 0 ? "unpushed" : "none")
            plan.checks[5] = LandCheck(name: "local_changes", state: c, blocks: c != "none")
            plan.checks[6] = LandCheck(name: "unpushed_commits", state: u, blocks: u != "none")
            plan.ready = false
            return try row(sheet(plan), "worktree")
        }
        let files = try local(changed: 2, unpushed: 0)
        #expect(files.title == "Worktree has local work" && files.value == "2 changed \u{00B7} 0 not pushed")
        #expect(files.hint == "Commit or push 2 files" && files.tone == .blocking && files.action == nil)
        #expect(try local(changed: 1, unpushed: 0).hint == "Commit or push 1 file")
        #expect(try local(changed: 0, unpushed: 3).hint == "Push 3 commits")
        #expect(try local(changed: 0, unpushed: 1).hint == "Push 1 commit")
        #expect(try local(changed: 2, unpushed: 3).hint == "Commit and push your work")
        let unknown = try local(changed: 0, unpushed: 0, unknown: true)
        #expect(unknown.title == "Loam could not read the worktree" && unknown.tone == .blocking)
    }

    @Test func twoBlockingRowsMakeTheFooterCountThem() throws {
        var plan = try with("checks", "failed", blocks: true)
        plan.checks[5] = LandCheck(name: "local_changes", state: "changed", blocks: true)
        plan.changed = 2
        let content = sheet(plan)
        #expect(content.blockingCount == 2 && !content.canMerge)
        #expect(content.footer == "Fix the 2 items in rust before you merge.")
    }

    @Test func aDraftBlocksAndOpensGitHub() throws {
        let plan = try with("github", "draft", blocks: true) { $0.stage = .draft }
        let content = sheet(plan)
        let github = try row(content, "github")
        #expect(github.title == "Draft pull request" && github.tone == .blocking && github.action == .openOnGitHub)
        #expect(github.value == "Mark it ready on GitHub")
        #expect(!content.canMerge)
    }

    @Test func aMergeThatGitHubBlocksShowsARowOnlyWhenItIsNotClear() throws {
        #expect(try ready().checks.contains { $0.name == "github" })
        #expect(!sheet(try ready()).rows.contains { $0.id == "github" })
        let blocked = sheet(try with("github", "blocked", blocks: true) { $0.stage = .blocked })
        let github = try row(blocked, "github")
        #expect(github.title == "GitHub blocks the merge" && github.tone == .blocking && github.action == .openOnGitHub)
        #expect(!blocked.canMerge)
        // Behind the merge queue it does not block.
        let waiting = try row(sheet(try with("github", "blocked")), "github")
        #expect(waiting.tone == .note)
    }

    @Test func aBlockedPlanNeverMergesWhateverTheModeIs() throws {
        for (queue, auto) in [(false, false), (true, false), (false, true)] {
            var plan = try with("review", "changes_requested", blocks: true)
            plan.mergeQueue = queue
            plan.checks[0] = LandCheck(name: "checks", state: auto ? "running" : "passed", blocks: false)
            let content = sheet(plan)
            #expect(!content.canMerge, "queue \(queue), auto \(auto)")
        }
    }

    // MARK: Behind base

    @Test func behindBaseDoesNotBlockAndOffersUpdateBranch() throws {
        let plan = try with("behind_base", "behind") { $0.pr.behindBase = 3 }
        let content = sheet(plan)
        let behind = try row(content, "behind_base")
        #expect(behind.title == "3 behind main" && behind.value == "Does not block the merge")
        #expect(behind.tone == .note && behind.action == .updateBranch)
        #expect(content.canMerge && content.blockingCount == 0)
    }

    @Test func behindBaseBlocksWhenTheBranchNeedsItUpToDate() throws {
        let plan = try with("behind_base", "behind", blocks: true) { $0.pr.behindBase = 1; $0.stage = .behindBase }
        let content = sheet(plan)
        let behind = try row(content, "behind_base")
        #expect(behind.title == "1 behind main" && behind.value == "GitHub needs it up to date")
        #expect(behind.tone == .blocking && behind.action == .updateBranch)
        #expect(!content.canMerge)
    }

    @Test func behindBaseWithNoCountStillSaysBehind() throws {
        let plan = try with("behind_base", "behind", blocks: true) { $0.pr.behindBase = 0 }
        #expect(try row(sheet(plan), "behind_base").title == "Behind main")
    }

    // MARK: Checks that still run

    @Test func checksThatRunGiveMergeWhenReady() throws {
        let plan = try with("checks", "running") {
            $0.stage = .checksRunning
            $0.pr.checks = PRCheckCounts(state: "PENDING", total: 14, passed: 9, failed: 0, running: 5, waiting: 0)
        }
        let content = sheet(plan)
        let checks = try row(content, "checks")
        #expect(checks.title == "Checks running" && checks.value == "9 of 14 done" && checks.tone == .note)
        #expect(content.primary == .mergeWhenReady && content.primaryTitle == "Merge when ready")
        #expect(content.usesAuto && content.canMerge)
        #expect(content.footer == "GitHub merges #22 when its checks pass. Loam tidies up after the merge.")
    }

    @Test func checksThatWaitForApprovalGiveMergeWhenReadyToo() throws {
        let plan = try with("checks", "waiting") {
            $0.pr.checks = PRCheckCounts(state: "PENDING", total: 4, passed: 1, failed: 0, running: 0, waiting: 3)
        }
        let content = sheet(plan)
        #expect(try row(content, "checks").title == "Checks wait for approval")
        #expect(try row(content, "checks").value == "3 waiting")
        #expect(content.primary == .mergeWhenReady && content.usesAuto)
    }

    // MARK: A merge queue

    @Test func aMergeQueueGivesAddToMergeQueueAndNoMethod() throws {
        var plan = try ready()
        plan.mergeQueue = true
        plan.method = ""
        let content = sheet(plan)
        #expect(content.primary == .addToMergeQueue && content.primaryTitle == "Add to merge queue")
        #expect(content.mergeQueue && content.canMerge)
        #expect(content.mergeMethods.isEmpty && content.defaultMethod == nil)
        #expect(content.footer == "The queue merges #22 after its checks pass on main.")
    }

    @Test func aMergeQueueWinsOverRunningChecks() throws {
        var plan = try with("checks", "running")
        plan.mergeQueue = true
        #expect(sheet(plan).primary == .addToMergeQueue)
        #expect(!sheet(plan).usesAuto)
    }

    // MARK: After the merge

    @Test func theFirstCheckboxNamesThePanes() throws {
        let plan = try ready()
        #expect(sheet(plan, panes: 0).removeLabel == "Remove the worktree")
        #expect(sheet(plan, panes: 1).removeLabel == "Close its pane and remove the worktree")
        #expect(sheet(plan, panes: 2).removeLabel == "Close its 2 panes and remove the worktree")
        #expect(sheet(plan).worktreeName == "link-labels")
    }

    @Test func aMergeThatWaitsDoesTheTidyUpLater() throws {
        #expect(sheet(try ready()).afterNote == nil)
        var queued = try ready()
        queued.mergeQueue = true
        #expect(sheet(queued).afterNote == "Loam does this when GitHub has merged the pull request.")
        let running = try with("checks", "running")
        #expect(sheet(running).afterNote == "Loam does this when GitHub has merged the pull request.")
        #expect(!sheet(running).canMoveWhereItStandsOn && !sheet(queued).canMoveWhereItStandsOn)
        #expect(sheet(try ready()).canMoveWhereItStandsOn)
    }

    // MARK: Where it stands

    @Test func whereItStandsGetsTheSentenceBeforeTheCurrentText() {
        let text = LandSheetContent.whereItStands(merged: 22, title: "Link labels", current: "Native panel spacing fails lint.")
        #expect(text.sentence == "Merged #22 Link labels.")
        #expect(text.text == "Merged #22 Link labels. Native panel spacing fails lint.")
    }

    @Test func whereItStandsKeepsOnlyTheSentenceWhenThePlotHasNoText() {
        let text = LandSheetContent.whereItStands(merged: 22, title: "Link labels", current: " \n ")
        #expect(text.text == "Merged #22 Link labels.")
    }

    @Test func whereItStandsDoesNotDoubleThePeriodOfATitle() {
        #expect(LandSheetContent.whereItStands(merged: 7, title: "Fix the cache.", current: "").sentence == "Merged #7 Fix the cache.")
        #expect(LandSheetContent.whereItStands(merged: 7, title: "Why?", current: "").sentence == "Merged #7 Why?")
        #expect(LandSheetContent.whereItStands(merged: 7, title: "   ", current: "").sentence == "Merged #7.")
    }

    @Test func whereItStandsMakesTheTitleOneLine() {
        // GitHub gives the title, and it can hold a line break or a direction mark.
        let text = LandSheetContent.whereItStands(merged: 7, title: "Fix\nthe\u{202E} cache", current: "Next: ship.")
        #expect(text.sentence == "Merged #7 Fix the cache.")
        #expect(!text.text.contains("\n"))
    }

    @Test func whereItStandsTrimsTheCurrentText() {
        let text = LandSheetContent.whereItStands(merged: 7, title: "Fix", current: "\n  Next: ship.  \n\n")
        #expect(text.text == "Merged #7 Fix. Next: ship.")
    }

    // MARK: A merged PR

    @Test func aPullRequestThatIsMergedAlreadyCannotBeMergedAgain() throws {
        var plan = try ready()
        plan.merged = true
        plan.pr.state = "MERGED"
        plan.checks = [LandCheck(name: "work_after_pr", state: "none", blocks: false)]
        plan.methods = []
        plan.defaultMethod = ""
        plan.method = ""
        let content = sheet(plan)
        #expect(content.isMerged && !content.canMerge)
        #expect(content.rows.isEmpty)
        #expect(content.footer == "#22 is merged on GitHub already.")
    }

    // MARK: Words

    @Test func rowActionsHaveTitles() {
        #expect(LandSheetContent.RowAction.send(.failures).title == "Send failures to session")
        #expect(LandSheetContent.RowAction.send(.review).title == "Send review to session")
        #expect(LandSheetContent.RowAction.send(.conflicts).title == "Send conflicts to session")
        #expect(LandSheetContent.RowAction.updateBranch.title == "Update branch")
        #expect(LandSheetContent.RowAction.openOnGitHub.title == "Open on GitHub")
    }

    // MARK: The toast

    func landed(_ edit: (inout LandResult) -> Void = { _ in }) throws -> LandResult {
        var result = try JSONDecoder().decode(LandResult.self, from: Fixtures.data("worktree_land"))
        result.pr.number = 22
        result.worktree.name = "link-labels"
        edit(&result)
        return result
    }

    @Test func theToastAfterAMergeNamesTheRemovedWorktree() throws {
        let toast = LandSheetContent.toast(for: try landed(), asked: .init())
        #expect(toast.text == "Merged #22. Removed the worktree link-labels." && toast.kind == .done)
    }

    @Test func aWorktreeThatYouKeptNeedsNoWord() throws {
        let toast = LandSheetContent.toast(for: try landed { $0.worktreeRemoved = false }, asked: .init(keepWorktree: true))
        #expect(toast.text == "Merged #22." && toast.kind == .done)
    }

    @Test func aWorktreeThatTheCoreKeptIsANotice() throws {
        let toast = LandSheetContent.toast(for: try landed { $0.worktreeRemoved = false }, asked: .init())
        #expect(toast.text == "Merged #22. Loam kept the worktree link-labels." && toast.kind == .notice)
    }

    @Test func aBranchThatGitHubKeptIsANoticeUnlessYouKeptIt() throws {
        let kept = try landed { $0.remoteBranchDeleted = false; $0.remoteBranchNote = "Kept the branch link-labels on GitHub: it has commits after the head." }
        #expect(LandSheetContent.toast(for: kept, asked: .init()).text
            == "Merged #22. Removed the worktree link-labels. Loam kept the branch on GitHub.")
        #expect(LandSheetContent.toast(for: kept, asked: .init()).kind == .notice)
        #expect(LandSheetContent.toast(for: try landed { $0.remoteBranchDeleted = false }, asked: .init(keepRemoteBranch: true)).kind == .done)
    }

    @Test func aMergeThatWaitsHasItsOwnWords() throws {
        let auto = try landed { $0.merged = false; $0.mergeLater = true; $0.auto = true; $0.worktreeRemoved = false }
        #expect(LandSheetContent.toast(for: auto, asked: .init()).text == "#22 will merge when its checks pass.")
        let queued = try landed { $0.merged = false; $0.mergeLater = true; $0.mergeQueue = true; $0.worktreeRemoved = false }
        #expect(LandSheetContent.toast(for: queued, asked: .init()).text == "Added #22 to the merge queue.")
        let unseen = try landed { $0.merged = false; $0.mergeLater = true; $0.mergeNote = "GitHub merged PR #22, but the PR does not show the merge yet." }
        let toast = LandSheetContent.toast(for: unseen, asked: .init())
        #expect(toast.text == "GitHub took #22, but Loam does not see the merge yet." && toast.kind == .notice)
    }
}
