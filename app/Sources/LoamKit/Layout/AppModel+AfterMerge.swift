import Foundation

/// After a merge on GitHub (ticket 113). A refresh can find that GitHub merged the PR of a worktree: you merged it on
/// GitHub, a reviewer did, or the merge queue or an auto merge did. Then, once for each merge in a run of the app:
///
/// 1. A land that ticket 111 recorded for that PR number tidies up as it says, with no callout.
/// 2. Else the repo setting decides. Ask shows a callout at the top of the plot panel. Remove the worktree removes it
///    when that is safe, and asks when it is not. Do nothing leaves the faded Merged row with its Remove… pill.
///
/// Removing a worktree can lose work, so Loam acts only on a PR whose state is MERGED, and removes a worktree with no
/// question only when git found no changed files and no unpushed commits, no session in it is mid-turn or needs you,
/// and no shell in it runs a process. Each check runs before a pane closes. A merge is not Needs you, and Loam does not
/// notify.
extension AppModel {
    // MARK: The refresh

    /// Decides on the merges that a refresh found in these worktrees, and acts on them after the refresh ended, so the
    /// spinner of the refresh does not wait for `gh`. A merge is decided here, before any wait, so it acts once in a run
    /// of the app, also when two refreshes find it. A kept merge, and a merge that a land of the Land sheet runs for
    /// now, do nothing. The actions run one after the other.
    func followMerges(of ids: [String]) {
        var found: [MergedPR] = []
        for id in ids {
            guard let row = worktreeStatus(id), let merge = AfterMergeRule.merge(of: row), !mergesDecided.contains(merge),
                  !keptMerges.contains(merge), !landSheetMerges(id) else { continue }
            mergesDecided.insert(merge)
            found.append(merge)
        }
        guard !found.isEmpty else { return }
        let before = mergeActions
        mergeActions = Task { [weak self] in
            await before?.value
            for merge in found { await self?.act(on: merge) }
        }
    }

    /// Returns when the actions after merges that run now have ended.
    func mergesSettled() async {
        var waited: Task<Void, Never>?
        while let running = mergeActions, running != waited {
            waited = running
            await running.value
        }
    }

    /// True when the Land sheet merges the worktree now. The land of the sheet tidies up itself.
    private func landSheetMerges(_ worktree: String) -> Bool {
        landSheet.isMerging && landSheet.worktreeID == worktree
    }

    /// False when the Land sheet began to merge the worktree during a wait. Then the merge is not decided, and a later
    /// refresh decides it. An action asks after each wait, before any pane closes and before any land or removal.
    private func stillDecided(_ merge: MergedPR) -> Bool {
        guard landSheetMerges(merge.worktree) else { return true }
        mergesDecided.remove(merge)
        return false
    }

    private func act(on merge: MergedPR) async {
        guard stillDecided(merge), let row = rowBeforeActing(merge) else { return }
        switch AfterMergeRule.action(for: merge, land: row.worktree.land) {
        case .tidy(let land): await tidyUp(merge, as: land)
        case .follow:
            let setting = await afterMergeSetting(of: row.worktree)
            guard stillDecided(merge) else { return }
            await follow(merge, setting: setting)
        }
    }

    /// The setting of the repo of the worktree, read when a merge needs it, so a change in another plot or by Claude
    /// counts. A failed read asks.
    private func afterMergeSetting(of worktree: Worktree) async -> AfterMerge {
        let plot = try? await client.show(plot: worktree.plotID)
        return plot?.repos.first { $0.path == worktree.repo }?.afterMerge ?? .ask
    }

    private func follow(_ merge: MergedPR, setting: AfterMerge) async {
        switch setting {
        case .keep: return
        case .ask: ask(merge)
        case .remove: await removeAfterMerge(merge)
        }
    }

    /// The row of the merge as the app knows it now, or nil when the worktree left the list or is not at that merge,
    /// such as after a refresh with no answer of GitHub. An action reads it again after each wait, since the row can
    /// change meanwhile.
    private func currentRow(_ merge: MergedPR) -> WorktreeStatus? {
        guard let row = worktreeStatus(merge.worktree), AfterMergeRule.merge(of: row) == merge else { return nil }
        return row
    }

    /// `currentRow` for an action that has not acted yet: no land, removal or callout. A nil row also takes the merge
    /// out of the decided merges, so a later refresh that finds the merge decides it again. A merge that acted stays
    /// decided, so a later change of the setting does not act on it.
    private func rowBeforeActing(_ merge: MergedPR) -> WorktreeStatus? {
        guard let row = currentRow(merge) else {
            mergesDecided.remove(merge)
            return nil
        }
        return row
    }

    /// True when the worktree can go with no question (`AfterMergeRule.canRemove`).
    private func canRemove(_ row: WorktreeStatus) -> Bool {
        AfterMergeRule.canRemove(row, panes: landPanes(of: row.worktree), in: workspace, runsAProcess: paneRunsAProcess)
    }

    /// Closes the panes of the worktree, and writes `state.json`, so the core counts none of them.
    private func closePanes(of worktree: Worktree) async {
        for pane in landPanes(of: worktree) { closePane(pane) }
        await paneClosesFinished()
        await stateWriter?.flushed()
    }

    // MARK: Remove the worktree

    /// The setting Remove the worktree.
    private func removeAfterMerge(_ merge: MergedPR) async {
        guard let row = rowBeforeActing(merge), await removeOrAsk(merge, row: row) else { return }
        await reloadWorktrees()
        onToast?(AfterMergeRule.removed(merge, name: row.worktree.name), .done)
    }

    /// Removes the worktree when it can go with no question. Else asks. A refusal of the core asks too, and shows in
    /// the panel. Remove worktree in a callout owns its worktree while it runs, also while its close question shows,
    /// so then this asks and closes nothing. Returns true when the worktree is gone.
    private func removeOrAsk(_ merge: MergedPR, row: WorktreeStatus) async -> Bool {
        guard canRemove(row), !mergeRemovals.contains(row.worktree.id) else {
            ask(merge)
            return false
        }
        do {
            try await removeWorktree(of: row)
            return true
        } catch {
            showRefusal(AfterMergeRule.refusal(error, for: row.worktree), plot: row.worktree.plotID)
            ask(merge)
            return false
        }
    }

    /// Closes the panes of the worktree, then runs `loam worktree rm` with no `--force`, so the core checks the work
    /// again. The core refuses a pane that is open in the worktree, so the panes close first. Throws the refusal of the
    /// core.
    private func removeWorktree(of row: WorktreeStatus) async throws {
        await closePanes(of: row.worktree)
        _ = try await client.worktreeRemove(plot: row.worktree.plotID, worktree: row.worktree.id,
                                            openPanes: openPaneFolders + savedPaneFolders())
    }

    // MARK: A recorded land

    /// Finishes a land that waited for GitHub (`--auto`, or a merge queue) as its options say. A land of a PR that is
    /// not merged would merge it, so a dry run must say first that the PR is merged, with the same number, and that the
    /// record is for that PR. A merged PR stays merged, so the land after it finds the same.
    ///
    /// No pane closes before the land: the land keeps the worktree (`--keep-worktree`), so the core needs no closed
    /// pane. It deletes the branch on GitHub unless the record keeps it, and clears the record. Then, unless the record
    /// keeps the worktree, the panes close and `loam worktree rm` removes it, as the land would. Asks when it is not
    /// safe, and when a step fails. The panel shows why a step failed.
    private func tidyUp(_ merge: MergedPR, as land: PendingLand) async {
        let removes = !land.keepWorktree
        guard let first = rowBeforeActing(merge) else { return }
        guard !removes || canRemove(first) else { return ask(merge) }
        let plan: LandResult
        do {
            plan = try await client.worktreeLand(plot: first.worktree.plotID, worktree: merge.worktree, dryRun: true)
        } catch {
            showRefusal(AfterMergeRule.refusal(error, for: first.worktree), plot: first.worktree.plotID)
            return ask(merge)
        }
        guard stillDecided(merge) else { return }
        guard plan.merged, plan.pr.state == "MERGED", plan.pr.number == merge.number, plan.worktree.land?.pr == merge.number
        else { return ask(merge) }
        guard let row = rowBeforeActing(merge) else { return }
        guard !removes || canRemove(row) else { return ask(merge) }
        var result: LandResult
        do {
            result = try await client.worktreeLand(plot: row.worktree.plotID, worktree: merge.worktree, keepWorktree: true,
                                                   head: plan.pr.headOID)
        } catch {
            showRefusal(AfterMergeRule.refusal(error, for: row.worktree), plot: row.worktree.plotID)
            return ask(merge)
        }
        if removes {
            // The land of the Land sheet tidies up the rest.
            guard stillDecided(merge) else { return }
            if let now = currentRow(merge), await removeOrAsk(merge, row: now) { result.worktreeRemoved = true }
        } else {
            // A keep that you chose stays quiet.
            keptMerges.keep(merge)
        }
        await reloadWorktrees()
        let asked = LandSheetContent.Request(keepWorktree: land.keepWorktree, keepRemoteBranch: land.keepRemoteBranch)
        let toast = LandSheetContent.toast(for: result, asked: asked)
        onToast?(toast.text, toast.kind)
    }

    // MARK: The callout

    private func ask(_ merge: MergedPR) {
        if !mergeAsks.contains(merge) { mergeAsks.append(merge) }
    }

    /// The callouts of a plot, oldest first.
    public func mergeAsks(in plot: String) -> [MergedPR] {
        mergeAsks.filter { worktreeStatus($0.worktree)?.worktree.plotID == plot }
    }

    /// A callout goes when its worktree leaves the list or is no longer at that merge.
    func followMergeAsks() {
        let next = mergeAsks.filter { currentRow($0) != nil }
        if next != mergeAsks { mergeAsks = next }
    }

    /// Keep: the callout goes, and the worktree stays with the faded Merged row and its Remove… pill. Loam remembers
    /// the keep for the worktree and the PR number, also after a restart.
    public func keepMerged(_ worktree: String) {
        guard let merge = mergeAsks.first(where: { $0.worktree == worktree }) else { return }
        mergeAsks.removeAll { $0 == merge }
        keptMerges.keep(merge)
    }

    /// Remembers a merge that the Land sheet made and that kept the worktree, so no callout asks about it.
    func keepLanded(_ worktree: String, number: Int) {
        keptMerges.keep(MergedPR(worktree: worktree, number: number))
    }

    /// Remove worktree in a callout: the steps of the Land sheet with no merge. Work that is not on GitHub refuses
    /// first, with no question and no pane closed (`workIsSafe`). Then the panes of the worktree close, and a session in
    /// a turn asks first. Then `loam worktree rm`, which deletes the local branch. Then the Where it stands card takes
    /// the keys, with "Merged #142 Link labels." before its text and selected. A refusal shows in the panel, and the
    /// callout stays.
    public func removeMergedWorktree(_ worktree: String) async {
        guard let merge = mergeAsks.first(where: { $0.worktree == worktree }), !mergeRemovals.contains(worktree) else { return }
        mergeRemovals.insert(worktree)
        defer { mergeRemovals.remove(worktree) }
        guard let first = currentRow(merge), await workIsSafe(first) else { return }
        if let prompt = ClosePrompt.make(.removeWorktree, closing: landPanes(of: first.worktree), in: workspace) {
            // A session in a turn can commit while the question shows.
            guard await confirmClose(prompt), let now = currentRow(merge), await workIsSafe(now) else { return }
        }
        guard let row = currentRow(merge), passesWorkCheck(row) else { return }
        do {
            try await removeWorktree(of: row)
        } catch {
            showRefusal(AfterMergeRule.refusal(error, for: row.worktree), plot: row.worktree.plotID)
            return
        }
        mergeAsks.removeAll { $0 == merge }
        await reloadWorktrees()
        if panel.plot?.id == row.worktree.plotID {
            panel.errorMessage = nil
            panel.prefillMerged(merge.number, title: row.pr?.title ?? "")
        }
    }

    /// True when the row has no changed files and no failed check, and a dry run of `loam worktree rm` finds no work
    /// that is not on GitHub. The core knows when the merged PR holds the commits that the row counts as unpushed, as
    /// after a squash merge, so the app leaves those commits to it. Else the panel shows why, and no pane closes.
    private func workIsSafe(_ row: WorktreeStatus) async -> Bool {
        guard passesWorkCheck(row) else { return false }
        do {
            _ = try await client.worktreeRemove(plot: row.worktree.plotID, worktree: row.worktree.id, dryRun: true)
            return true
        } catch {
            showRefusal(AfterMergeRule.refusal(error, for: row.worktree), plot: row.worktree.plotID)
            return false
        }
    }

    /// True when the row has no changed files and no failed check. Else the panel shows why the core would refuse,
    /// with the words of the Remove worktree dialog.
    private func passesWorkCheck(_ row: WorktreeStatus) -> Bool {
        guard row.changed > 0 || row.error != nil else { return true }
        let plan = WorktreeRemovalPlan.needsForce(changed: row.changed, unpushed: 0, checkError: row.error)
        showRefusal(plan.message(for: row.worktree), plot: row.worktree.plotID)
        return false
    }

    /// The panel shows a refusal only while it shows the plot of the worktree.
    private func showRefusal(_ message: String, plot: String) {
        if panel.plot?.id == plot { panel.errorMessage = message }
    }
}
