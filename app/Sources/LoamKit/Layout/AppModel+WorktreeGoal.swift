import Foundation

/// The goal of a worktree (ticket 115): `loam worktree edit --goal`, as one change with Undo. The PR popover of a worktree
/// with no PR edits it in place: a click on the Goal row starts the edit, Return saves, and Escape cancels.
extension AppModel {
    /// Sets the goal of a worktree. The edit expects the version that the row has, so a goal that a session changed
    /// meanwhile is not lost. An empty goal clears it. Returns the message when it did not save, else nil.
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

    /// The Goal row of the open popover: opens the edit with the goal as it is. Does nothing when the row shows no
    /// Goal row (a worktree with a PR).
    public func beginGoalEdit() {
        guard let id = prPopover.worktreeID, let status = worktreeStatus(id), PRPopoverContent(status).goal != nil else { return }
        prPopover.beginGoalEdit(status.worktree.goal ?? "")
    }

    public func cancelGoalEdit() { prPopover.cancelGoalEdit() }

    /// Return in the goal field. A failure leaves the edit open with the message.
    public func saveGoalEdit() async {
        guard let id = prPopover.worktreeID, let draft = prPopover.goalDraft, !prPopover.isSavingGoal else { return }
        let open = prPopover.openCount
        prPopover.beginSavingGoal()
        let problem = await setWorktreeGoal(id, to: draft)
        // A popover that closed or opened again meanwhile has dropped the edit.
        guard prPopover.isOpen, prPopover.openCount == open, prPopover.isSavingGoal else { return }
        if let problem { prPopover.goalFailed(problem) } else { prPopover.cancelGoalEdit() }
    }
}
