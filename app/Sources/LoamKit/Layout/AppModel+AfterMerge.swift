import Foundation

/// After a merge on GitHub (ticket 113). A refresh can find that GitHub merged the PR of a worktree: you merged it on
/// GitHub, a reviewer did, or the merge queue or an auto merge did. Then, once for each merge in a run of the app:
///
/// 1. A land that ticket 111 recorded for that PR number tidies up as it says, with no callout.
/// 2. Else the repo setting decides. Ask shows a callout at the top of the plot panel. Remove the worktree removes it
///    when that is safe, and asks when it is not. Do nothing leaves the faded Merged row with its Remove… pill.
///
/// Removing a worktree can lose work, so Loam acts only on a PR whose state is MERGED, and removes a worktree only
/// when git found no changed files and no unpushed commits, and no session in it is mid-turn or needs you. A merge is
/// not Needs you, and Loam does not notify.
extension AppModel {
    // MARK: The refresh

    /// Acts on the merges that a refresh found in these worktrees. A merge acts once in a run of the app. A kept merge
    /// and a merge that a land of the Land sheet runs for now do nothing.
    func followMerges(of ids: [String]) async {
        for id in ids {
            guard let row = worktreeStatus(id), let merge = AfterMergeRule.merge(of: row),
                  !mergesDecided.contains(merge), !keptMerges.contains(merge) else { continue }
            // The land of the Land sheet tidies up itself. A later refresh decides when it did not.
            if landSheet.isMerging, landSheet.worktreeID == id { continue }
            mergesDecided.insert(merge)
            switch AfterMergeRule.action(for: merge, land: row.worktree.land) {
            case .tidy(let land): await tidyUp(merge, as: land)
            case .follow: await follow(merge, setting: await afterMergeSetting(of: row.worktree))
            }
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

    /// The row of the merge as the app knows it now, or nil when the worktree left the list or is not at that merge.
    /// An action reads it again after each wait, since the row can change meanwhile.
    private func currentRow(_ merge: MergedPR) -> WorktreeStatus? {
        guard let row = worktreeStatus(merge.worktree), AfterMergeRule.merge(of: row) == merge else { return nil }
        return row
    }

    /// True when the worktree can go with no question (`AfterMergeRule.canRemove`).
    private func canRemove(_ row: WorktreeStatus) -> Bool {
        AfterMergeRule.canRemove(row, panes: landPanes(of: row.worktree), in: workspace)
    }

    /// Closes the panes of the worktree, and writes `state.json`, so the core counts none of them.
    private func closePanes(of worktree: Worktree) async {
        for pane in landPanes(of: worktree) { closePane(pane) }
        await paneClosesFinished()
        await stateWriter?.flushed()
    }

    // MARK: Remove the worktree

    /// The setting Remove the worktree: closes the panes, then `loam worktree rm` with no `--force`, so the core also
    /// refuses work that is not on GitHub. Asks when it is not safe, and when the core refuses.
    private func removeAfterMerge(_ merge: MergedPR) async {
        guard let row = currentRow(merge), canRemove(row) else { return ask(merge) }
        let worktree = row.worktree
        await closePanes(of: worktree)
        do {
            _ = try await client.worktreeRemove(plot: worktree.plotID, worktree: worktree.id,
                                                openPanes: openPaneFolders + savedPaneFolders())
        } catch {
            return ask(merge)
        }
        await reloadWorktrees()
        onToast?(AfterMergeRule.removed(merge, name: worktree.name), .done)
    }

    // MARK: A recorded land

    /// Finishes a land that waited for GitHub (`--auto`, or a merge queue) as its options say: `loam worktree land` with
    /// no flags applies the keeps that the worktree records. A land of a PR that is not merged would merge it, so a
    /// dry run must say first that the PR is merged, with the same number, and that the record is for that PR. A
    /// merged PR stays merged, so the land after it finds the same. Asks when it is not safe, and when a step fails.
    private func tidyUp(_ merge: MergedPR, as land: PendingLand) async {
        guard let first = currentRow(merge), land.keepWorktree || canRemove(first) else { return ask(merge) }
        let plot = first.worktree.plotID
        let plan: LandResult
        do {
            plan = try await client.worktreeLand(plot: plot, worktree: merge.worktree, dryRun: true)
        } catch {
            return ask(merge)
        }
        guard plan.merged, plan.pr.state == "MERGED", plan.pr.number == merge.number, plan.worktree.land?.pr == merge.number,
              let row = currentRow(merge) else { return ask(merge) }
        if !land.keepWorktree {
            guard canRemove(row) else { return ask(merge) }
            await closePanes(of: row.worktree)
        }
        let result: LandResult
        do {
            result = try await client.worktreeLand(plot: plot, worktree: merge.worktree, head: plan.pr.headOID,
                                                   openPanes: openPaneFolders + savedPaneFolders())
        } catch {
            return ask(merge)
        }
        let asked = LandSheetContent.Request(keepWorktree: land.keepWorktree, keepRemoteBranch: land.keepRemoteBranch)
        if !result.worktreeRemoved {
            // A keep that you chose stays quiet. A worktree that the core could not remove asks.
            if land.keepWorktree { keptMerges.keep(merge) } else { ask(merge) }
        }
        await reloadWorktrees()
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

    /// Remove worktree in a callout: the steps of the Land sheet with no merge. The panes of the worktree close, and a
    /// session in a turn asks first. Then `loam worktree rm`, which deletes the local branch. Then the Where it stands
    /// card takes the keys, with "Merged #142 Link labels." before its text and selected. A refusal of the core shows in
    /// the panel, and the callout stays.
    public func removeMergedWorktree(_ worktree: String) async {
        guard let merge = mergeAsks.first(where: { $0.worktree == worktree }), !mergeRemovals.contains(worktree),
              let row = currentRow(merge) else { return }
        mergeRemovals.insert(worktree)
        defer { mergeRemovals.remove(worktree) }
        if let prompt = ClosePrompt.make(.removeWorktree, closing: landPanes(of: row.worktree), in: workspace),
           !(await confirmClose(prompt)) { return }
        guard let row = currentRow(merge) else { return }
        await closePanes(of: row.worktree)
        do {
            _ = try await client.worktreeRemove(plot: row.worktree.plotID, worktree: worktree,
                                                openPanes: openPaneFolders + savedPaneFolders())
        } catch {
            panel.errorMessage = Self.message(for: error)
            return
        }
        mergeAsks.removeAll { $0 == merge }
        await reloadWorktrees()
        if panel.plot?.id == row.worktree.plotID {
            panel.errorMessage = nil
            panel.prefillMerged(merge.number, title: row.pr?.title ?? "")
        }
    }
}
