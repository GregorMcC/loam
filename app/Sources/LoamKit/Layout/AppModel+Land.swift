import Foundation

/// The Land sheet (ticket 112): `loam worktree land` for one worktree, from the dry run to the toast. A merge on GitHub
/// cannot be undone, so the steps go in a fixed order, and a step that fails stops the ones after it:
///
/// 1. The dry run decides. The merge never starts while any row of the plan blocks (`LandSheetContent.canMerge`).
/// 2. For a merge now, with the first box on, the panes of the worktree close. A session in a turn asks first, and
///    Cancel there cancels the land.
/// 3. `loam worktree land` runs. A failure leaves the sheet open with the message of GitHub or of the core.
/// 4. With the third box on, Where it stands is saved as a change with Undo.
/// 5. The sheet closes, and the toast says what happened.
extension AppModel {
    // MARK: Open and close

    /// Opens the Land sheet for a worktree with a PR, and reads the plan (`loam worktree land --dry-run`) and Where it
    /// stands. The checklist shows a spinner until they are back. The PR popover closes, since one overlay shows at a
    /// time. Returns false for an unknown worktree, for one with no PR, and while a merge runs: an open would drop the
    /// state of that merge.
    @discardableResult
    public func openLandSheet(_ id: String) -> Bool {
        guard !landSheet.isMerging, let status = worktreeStatus(id), status.pr != nil else { return false }
        closePullRequest()
        landSheet.open(id)
        let open = landSheet.openCount
        landSheet.reading = Task { [weak self] in await self?.readLandPlan(id, open: open, first: true) }
        return true
    }

    /// Closes the sheet. A merge that runs cannot stop, so the sheet stays until it ends.
    public func closeLandSheet() {
        guard landSheet.isOpen, !landSheet.isMerging else { return }
        landSheet.close()
    }

    /// A worktree that left the list (a land removed it, or the folder and the record are gone) has nothing to land.
    /// The sheet that runs a merge stays until the merge ends.
    func followLandSheet() {
        guard let id = landSheet.worktreeID, !landSheet.isMerging, worktreeStatus(id) == nil else { return }
        landSheet.close()
    }

    /// The panes that run in the worktree, open or saved. The core counts the same panes by their folders.
    public func landPanes(of worktree: Worktree) -> [PaneID] {
        workspace.allPaneIDs.filter { pane in
            workspace.folder(of: pane).map { WorktreeRules.contains(worktreePath: worktree.path, folder: $0) } ?? false
        }
    }

    /// The words of the sheet for the plan that it shows. Nil until the plan is back.
    public var landContent: LandSheetContent? {
        guard let plan = landSheet.plan else { return nil }
        return LandSheetContent(plan, openPanes: landPanes(of: plan.worktree).count)
    }

    // MARK: The plan

    /// Reads the plan. The first read of an open also reads Where it stands, with its version, for the box under the
    /// third checkbox. A read for an open that is over is dropped.
    private func readLandPlan(_ id: String, open: Int, first: Bool = false) async {
        guard let plot = worktreeStatus(id)?.worktree.plotID else { return }
        do {
            async let plan = client.worktreeLand(plot: plot, worktree: id, dryRun: true)
            async let current = first ? client.show(plot: plot) : nil
            let (read, text) = try await (plan, current)
            guard landSheet.isCurrent(open) else { return }
            landSheet.loaded(read, where: text.map { ($0.whereItStands, $0.versions["where"]) })
        } catch {
            guard landSheet.isCurrent(open) else { return }
            landSheet.failed(Self.message(for: error))
        }
    }

    // MARK: Merge

    /// The primary button: merges, queues, or sets up the merge for when the checks pass. Does nothing while a check
    /// of the plan blocks, so a stale click or a key can never merge a worktree that the sheet shows as not ready.
    public func land() async {
        guard let id = landSheet.worktreeID, !landSheet.isMerging, !landSheet.isUpdating,
              let plan = landSheet.plan, let content = landContent, content.canMerge else { return }
        let open = landSheet.openCount
        let worktree = plan.worktree
        // A merge now removes the worktree, so its panes close first. A merge that waits leaves the tidy up for later.
        let now = !content.usesAuto && !content.mergeQueue
        let asked = LandSheetContent.Request(keepWorktree: !landSheet.removesWorktree, keepRemoteBranch: !landSheet.deletesBranch)
        let method = landSheet.effectiveMethod(for: content)
        landSheet.beginMerging()

        if now, landSheet.removesWorktree {
            let panes = landPanes(of: worktree)
            if let prompt = ClosePrompt.make(.land, closing: panes, in: workspace), !(await confirmClose(prompt)) {
                landSheet.endMerging()
                return
            }
            for pane in landPanes(of: worktree) { closePane(pane) }
            await paneClosesFinished()
            // The core reads the panes of state.json. Write a pending change first, so a pane that closed less than a
            // second ago does not count.
            await stateWriter?.flushed()
        }

        let result: LandResult
        do {
            // The commit that the sheet showed. A PR that has another head by now stops the land (exit 16), so the
            // merge never takes a commit that the checklist did not cover.
            result = try await client.worktreeLand(
                plot: worktree.plotID, worktree: id, method: method, auto: content.usesAuto, keepWorktree: asked.keepWorktree,
                keepRemoteBranch: asked.keepRemoteBranch, head: plan.pr.headOID, openPanes: openPaneFolders + savedPaneFolders())
        } catch {
            landSheet.mergeFailed(Self.message(for: error))
            if case LoamError.notReady = error {
                // A check that blocks now, or a new commit (exit 16), changed the PR since the dry run. The old plan
                // goes, so Merge stays off until the rows show what GitHub says now.
                landSheet.readingAgain()
                await readLandPlan(id, open: open)
            }
            // The worktree can be gone by now, such as when it was removed while the merge ran.
            followLandSheet()
            return
        }

        var toast = LandSheetContent.toast(for: result, asked: asked)
        if result.merged, landSheet.movesWhereItStandsOn, content.canMoveWhereItStandsOn,
           let problem = await saveWhereItStands(worktree.plotID, merged: result.pr.number) {
            toast = (toast.text + " " + problem, .notice)
        }
        await reloadWorktrees()
        landSheet.close()
        onToast?(toast.text, toast.kind)
    }

    /// Saves the text of the box as Where it stands, as the panel does: one change with Undo, expecting the version
    /// that the sheet read. Returns the sentence for the toast when it did not save, else nil.
    private func saveWhereItStands(_ plot: String, merged number: Int) async -> String? {
        let text = landSheet.whereText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        do {
            let saved = try await client.set(plot: plot, field: .whereItStands, text: text,
                                             expect: landSheet.whereVersion.map { ["where": $0] } ?? [:])
            onOwnChange?(saved.revision)
            await review.reload()
            await reloadPanel()
            return nil
        } catch LoamError.stale {
            return "Where it stands changed meanwhile, so Loam did not save it."
        } catch {
            return "Loam could not save Where it stands: \(Self.message(for: error))"
        }
    }

    // MARK: Rows

    /// Update branch on a row: `loam worktree update`, then the plan again.
    public func updateBranchFromLandSheet() async {
        guard let id = landSheet.worktreeID, !landSheet.isMerging, !landSheet.isUpdating,
              let plot = worktreeStatus(id)?.worktree.plotID else { return }
        let open = landSheet.openCount
        landSheet.beginUpdating()
        do {
            _ = try await client.worktreeUpdate(plot: plot, worktree: id)
        } catch {
            if landSheet.isCurrent(open) { landSheet.endUpdating(error: Self.message(for: error)) }
            return
        }
        await readLandPlan(id, open: open)
        if landSheet.isCurrent(open) { landSheet.endUpdating() }
        // GitHub changed the PR, so the row asks about it again too.
        await refreshWorktree(id, afterChange: true)
    }

    /// Send to session on a row (ticket 110). The sheet closes first, since the prompt goes to a pane. When Loam cannot
    /// type, the PR popover opens instead and says why (`sendFromMenu`).
    public func sendFromLandSheet(_ kind: FixPrompt.Kind) async {
        guard let id = landSheet.worktreeID, !landSheet.isMerging else { return }
        if sendPlan(for: id)?.prompt.kind != kind { await refreshWorktree(id) }
        guard sendPlan(for: id)?.prompt.kind == kind else {
            landSheet.showError("The pull request changed since the sheet read it. Close the sheet and open it again.")
            return
        }
        closeLandSheet()
        sendFromMenu(id)
    }
}
