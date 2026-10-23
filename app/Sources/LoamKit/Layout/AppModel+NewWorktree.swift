import Foundation

/// The New worktree sheet (ticket 115): from "New worktree…", the plus of the Worktrees section, or Start work… on an
/// issue link, to a seeded session in the new worktree. The sheet checks the branch as you type
/// (`loam worktree new --dry-run`), so a name that the core would refuse never reaches `loam worktree new`.
extension AppModel {
    // MARK: Open and close

    /// False while a merge runs, since the sheet would open over it, and while a worktree is made, since a new open would
    /// take back the state of that start.
    public var canOpenNewWorktree: Bool { !landSheet.isMerging && !newWorktreeSheet.isStarting }

    /// Opens the sheet for a plot, and reads its repos and links. `link` is the link of Start work…: the sheet takes the
    /// branch, the goal and the Link field from it. Returns false when it cannot open (`canOpenNewWorktree`). Every entry
    /// goes through here: the plot menu, the plus, the switcher and the link menu.
    @discardableResult
    public func openNewWorktree(plot: String, from link: PlotLink? = nil) -> Bool {
        guard canOpenNewWorktree else { return false }
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
        // A name that starts with a hyphen is refused in the sheet. `loam` would read it as a flag.
        guard sheet.isOpen, let request = sheet.request, !request.name.hasPrefix("-") else { return }
        let open = sheet.openCount
        let stamp = sheet.stamp
        sheet.checking = Task { [weak self] in
            try? await Task.sleep(for: sheet.checkDelay)
            guard !Task.isCancelled, let self, sheet.isCurrent(open) else { return }
            do {
                let result = try await client.worktreeCheck(plot: request.plot, repo: request.repo, name: request.name,
                                                            base: request.base, goal: request.goal, link: request.link)
                guard !Task.isCancelled, sheet.isCurrent(open) else { return }
                sheet.checked(result, stamp: stamp)
            } catch {
                guard !Task.isCancelled, sheet.isCurrent(open) else { return }
                sheet.checkFailed(Self.message(for: error), stamp: stamp)
            }
            // A Return that waited for this answer starts now, if the answer allows it. The start has a task of its own: a
            // change of a field cancels this task, and a cancel makes `LoamClient` stop `loam worktree new` in the middle.
            if sheet.takeQueuedStart() {
                sheet.queuedStart = Task { [weak self] in await self?.startNewWorktree() }
            }
        }
    }

    // MARK: Start

    /// Start session: `loam worktree new`, then a seeded session in the new worktree (`openWorktreePane`). While the plot
    /// is read or the check runs, the start waits for the answer (`queueStart`). It never makes a worktree that the sheet
    /// shows as not good. A failure leaves the sheet open with the message of the core.
    public func startNewWorktree() async {
        let sheet = newWorktreeSheet
        guard sheet.isOpen, !sheet.isStarting else { return }
        guard sheet.canStart, let request = sheet.startRequest else {
            // The plot or the check is on its way: start when it is back. Any other reason shows in a note.
            sheet.queueStart()
            return
        }
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
}
