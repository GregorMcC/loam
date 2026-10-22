import Foundation

/// The goal of a worktree (ticket 115): `loam worktree edit --goal`, as one change with Undo. The PR popover of a worktree
/// with no PR edits it in place: a click on the Goal row starts the edit, Return saves, and Escape cancels.
extension AppModel {
    /// How a save of the goal ended.
    public enum GoalSave: Equatable, Sendable {
        case saved
        /// The goal changed after `expect` was read. Nothing was saved, and the rows are read again.
        case changed
        /// Not saved. The text is the message of the core.
        case failed(String)
    }

    /// Sets the goal of a worktree. The edit expects `version`, the version that you read, so a goal that a session set
    /// meanwhile is not lost. An empty goal clears it.
    public func setWorktreeGoal(_ id: String, to goal: String, expect version: Int?) async -> GoalSave {
        guard let worktree = worktreeStatus(id)?.worktree else { return .failed("The worktree is gone.") }
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let edited = try await client.worktreeEdit(plot: worktree.plotID, worktree: id, goal: text, expect: version)
            // The action bar shows the changes of others, not this one.
            if edited.changeID > 0 { onOwnChange?(edited.changeID) }
        } catch LoamError.stale {
            await reloadWorktrees()
            return .changed
        } catch {
            return .failed(Self.message(for: error))
        }
        await reloadWorktrees()
        return .saved
    }

    /// The Goal row of the open popover: opens the edit with the goal and its version as they are now. Does nothing when
    /// the row shows no Goal row (a worktree with a PR).
    public func beginGoalEdit() {
        guard let id = prPopover.worktreeID, let status = worktreeStatus(id), PRPopoverContent(status).goal != nil else { return }
        prPopover.beginGoalEdit(status.worktree.goal ?? "", version: status.worktree.version)
    }

    public func cancelGoalEdit() { prPopover.cancelGoalEdit() }

    /// Return in the goal field. The save expects the version that the edit opened with. A failure leaves the edit open
    /// with the message. A goal that changed meanwhile shows in the field, in place of your draft.
    public func saveGoalEdit() async {
        guard let id = prPopover.worktreeID, let draft = prPopover.goalDraft, !prPopover.isSavingGoal else { return }
        let open = prPopover.openCount
        prPopover.beginSavingGoal()
        let saved = await setWorktreeGoal(id, to: draft, expect: prPopover.goalVersion)
        // A popover that closed or opened again meanwhile has dropped the edit.
        guard prPopover.isOpen, prPopover.openCount == open, prPopover.isSavingGoal else { return }
        switch saved {
        case .saved:
            prPopover.cancelGoalEdit()
        case .failed(let message):
            prPopover.goalFailed(message)
        case .changed:
            // The read after the stale answer gave the row as it is now. A worktree that is gone or has a PR has no edit.
            guard let status = worktreeStatus(id), PRPopoverContent(status).goal != nil else { return prPopover.cancelGoalEdit() }
            prPopover.goalChanged(to: status.worktree.goal ?? "", version: status.worktree.version,
                                  message: "The goal changed meanwhile. Loam shows the new goal.")
        }
    }
}
