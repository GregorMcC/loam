import Foundation

/// The New worktree sheet (ticket 115): from "New worktree…", the plus of the Worktrees section, or Start work… on an
/// issue link, to a seeded session in the new worktree. The sheet checks the branch as you type
/// (`loam worktree new --dry-run`), so a name that the core would refuse never reaches `loam worktree new`.
extension AppModel {
    // MARK: Open and close

    /// Opens the sheet for a plot, and reads its repos and links. `link` is the link of Start work…: the sheet takes the
    /// branch, the goal and the Link field from it. Returns false while a merge runs, since the sheet would open over it.
    @discardableResult
    public func openNewWorktree(plot: String, from link: PlotLink? = nil) -> Bool {
        guard !landSheet.isMerging else { return false }
        let sheet = newWorktreeSheet
        sheet.onInput = { [weak self] in self?.scheduleNewWorktreeCheck() }
        sheet.open(plot: plot, link: link)
        let open = sheet.openCount
        sheet.reading = Task { [weak self] in await self?.readNewWorktreePlot(plot, open: open) }
        return true
    }

    /// Closes the sheet. A worktree that is made now cannot stop, so the sheet stays until it is done.
    public func closeNewWorktree() {
        guard newWorktreeSheet.isOpen, !newWorktreeSheet.isStarting else { return }
        newWorktreeSheet.close()
    }

    /// The repos and the links of the plot. A read for an open that is over is dropped.
    private func readNewWorktreePlot(_ plot: String, open: Int) async {
        let sheet = newWorktreeSheet
        do {
            let read = try await client.show(plot: plot)
            guard sheet.isCurrent(open) else { return }
            sheet.loaded(read)
        } catch {
            guard sheet.isCurrent(open) else { return }
            sheet.failedToLoad(Self.message(for: error))
        }
    }

    // MARK: Check

    /// Runs the check for the fields as they are, after the short delay of the sheet. Each change of a field calls it, and
    /// a call cancels the one before, so only the last change asks the core.
    func scheduleNewWorktreeCheck() {
        let sheet = newWorktreeSheet
        sheet.checking?.cancel()
        sheet.checking = nil
        guard sheet.isOpen, let request = sheet.request else { return }
        let open = sheet.openCount
        let revision = sheet.inputRevision
        sheet.checking = Task { [weak self] in
            try? await Task.sleep(for: sheet.checkDelay)
            guard !Task.isCancelled, let self, sheet.isCurrent(open) else { return }
            do {
                let result = try await client.worktreeCheck(plot: request.plot, repo: request.repo, name: request.name,
                                                            base: request.base, goal: request.goal, link: request.link)
                guard !Task.isCancelled, sheet.isCurrent(open) else { return }
                sheet.checked(result, revision: revision)
            } catch {
                guard !Task.isCancelled, sheet.isCurrent(open) else { return }
                sheet.checkFailed(Self.message(for: error), revision: revision)
            }
        }
    }

    // MARK: Start

    /// Start session: `loam worktree new`, then a seeded session in the new worktree (`openWorktreePane`). Does nothing
    /// while the check blocks, so a key can never make a worktree that the sheet shows as not good. A failure leaves
    /// the sheet open with the message of the core.
    public func startNewWorktree() async {
        let sheet = newWorktreeSheet
        guard sheet.isOpen, sheet.canStart, let request = sheet.startRequest else { return }
        let open = sheet.openCount
        sheet.beginStarting()
        let made: WorktreeNewResult
        do {
            made = try await client.worktreeNew(plot: request.plot, repo: request.repo, name: request.name, base: request.base,
                                                goal: request.goal, link: request.link)
        } catch {
            if sheet.isCurrent(open) { sheet.startFailed(Self.message(for: error)) }
            return
        }
        lastError = nil
        await reloadWorktrees()
        if sheet.isCurrent(open) { sheet.close() }
        openWorktreePane(made.worktree)
    }

    // MARK: Goal

    /// Sets the goal of a worktree: `loam worktree edit --goal`, as one change with Undo. The edit expects the version that
    /// the row has, so a goal that a session changed meanwhile is not lost. An empty goal clears it. Returns the message
    /// when it did not save, else nil.
    public func setWorktreeGoal(_ id: String, to goal: String) async -> String? {
        guard let worktree = worktreeStatus(id)?.worktree else { return "The worktree is gone." }
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await client.worktreeEdit(plot: worktree.plotID, worktree: id, goal: text, expect: worktree.version)
        } catch LoamError.stale {
            await reloadWorktrees()
            return "The goal changed meanwhile. Loam shows the new goal."
        } catch {
            return Self.message(for: error)
        }
        await reloadWorktrees()
        return nil
    }
}
