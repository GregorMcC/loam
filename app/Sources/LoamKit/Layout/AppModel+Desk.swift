import Foundation

extension AppModel {
    /// The runs that wait for you at the desk: Shaping, then Ready to land, then Stopped, each the longest wait
    /// first. Nothing starts until you approve a draft, so drafts come first.
    public var deskQueue: [Run] {
        let oldestFirst = runs.reversed()
        return [RunState.shaping, .ready, .stopped].flatMap { state in oldestFirst.filter { $0.state == state } }
    }

    /// The run that the desk shows.
    public var deskRun: Run? { desk.runID.flatMap { id in runs.first { $0.id == id } } }

    /// Shows the desk on the run, or on the first run of the queue, and reads its work.
    public func openDesk(_ runID: String? = nil) async {
        page = .desk
        await showDeskItem(runID ?? deskQueue.first?.id)
    }

    /// Leaves the desk for Today. Your notes stay for the next visit.
    public func leaveDesk() {
        page = .today
    }

    /// Shows the next run of the queue, or with a negative offset an earlier one. The desk stays at the ends.
    public func moveDesk(by offset: Int) async {
        let queue = deskQueue
        guard !queue.isEmpty else { return }
        let index = queue.firstIndex { $0.id == desk.runID } ?? 0
        let next = queue[min(max(index + offset, 0), queue.count - 1)].id
        guard next != desk.runID else { return }
        await showDeskItem(next)
    }

    /// Shows a file of the diff.
    public func showDeskFile(_ path: String) {
        desk.file = path
    }

    /// Keeps the worktree after the merge, or removes it.
    public func setDeskKeepWorktree(_ keep: Bool) {
        desk.keepWorktree = keep
    }

    /// Adds a note on a line of a file, or with no file, on the whole run. A note with no text is not added.
    public func addDeskNote(file: String?, line: Int?, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = desk.runID, !text.isEmpty else { return }
        desk.notes[id, default: []].append(DeskNote(file: file, line: line, text: text))
    }

    public func removeDeskNote(_ noteID: UUID) {
        guard let id = desk.runID else { return }
        desk.notes[id]?.removeAll { $0.id == noteID }
        if desk.notes[id]?.isEmpty == true { desk.notes[id] = nil }
    }

    /// Sends your notes on the run back to its session (`loam run send-back`), and shows the next run.
    public func sendBackDeskNotes() async {
        guard let id = desk.runID, !desk.busy, !desk.currentNotes.isEmpty else { return }
        let notes = desk.currentNotes.map(\.argument)
        await deskAction(id) {
            _ = try await self.client.runSendBack(id, notes: notes)
            self.desk.notes[id] = nil
        }
    }

    /// Merges the PR of the run (`loam run land`), with the head of the diff that you read, and shows the
    /// next run. A merge that the core refuses keeps the run, and `desk.error` says why. The core keeps a
    /// worktree that has open panes, so the desk closes none. The merge can remove the worktree, so the
    /// worktrees are read again, and the toast says what the merge did, as at the Land sheet.
    public func landDeskRun() async {
        guard let id = desk.runID, !desk.busy else { return }
        let head = desk.diff?.head
        let keep = desk.keepWorktree
        let panes = openPaneFolders + savedPaneFolders()
        var landed: RunLandResult?
        await deskAction(id) {
            landed = try await self.client.runLand(id, head: head, keepWorktree: keep, openPanes: panes)
        }
        guard let landed else { return }
        await reloadWorktrees()
        let toast = LandSheetContent.toast(for: landed.land, asked: .init(keepWorktree: keep))
        onToast?(toast.text, toast.kind)
    }

    // MARK: Shape

    /// Edits the goal of the draft. A goal that is the same as the draft is no edit.
    public func editDeskGoal(_ goal: String) {
        editDeskShape { edit, run in
            let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            edit.goal = goal == run.goal ? nil : goal
        }
    }

    /// Replaces the checks of the draft. Checks that are the same as the draft are no edit.
    public func editDeskChecks(_ checks: [RunCheck]) {
        editDeskShape { edit, run in edit.checks = checks == run.doneWhen ? nil : checks }
    }

    /// Says what you want in place of an assumption of the draft. No text keeps the assumption.
    public func answerDeskAssumption(_ index: Int, _ answer: String) {
        editDeskShape { edit, _ in
            let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            edit.answers[index] = answer.isEmpty ? nil : answer
        }
    }

    private func editDeskShape(_ change: (inout ShapeEdit, Run) -> Void) {
        guard let run = deskRun, run.state == .shaping else { return }
        var edit = desk.shapeEdits[run.id] ?? ShapeEdit()
        change(&edit, run)
        desk.shapeEdits[run.id] = edit.isEmpty ? nil : edit
    }

    /// Starts the run with its draft and your edits (`loam run approve`), and shows the next run. After the core
    /// refused a new setup command, this approval approves it.
    public func approveDeskRun() async {
        guard let id = desk.runID, !desk.busy, !desk.drafting.contains(id) else { return }
        let edit = desk.currentEdit
        let approveSetup = desk.needsSetupApproval
        await deskAction(id) {
            _ = try await self.client.runApprove(id, goal: edit.goal, checks: edit.checks, answers: edit.answers,
                                                 approveSetup: approveSetup)
            self.desk.shapeEdits[id] = nil
        }
    }

    /// Claude drafts the run again with your change (`loam run redraft`). The draft takes a while, so the desk
    /// stays free: you can look at other runs while Claude drafts.
    public func redraftDeskRun(change: String) async {
        let change = change.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = desk.runID, !change.isEmpty, !desk.drafting.contains(id) else { return }
        desk.drafting.insert(id)
        desk.error = nil
        defer { desk.drafting.remove(id) }
        do {
            _ = try await client.runRedraft(id, change: change)
        } catch {
            if desk.runID == id { desk.error = Self.message(for: error) }
            return
        }
        await reloadRuns()
    }

    /// Not now: cancels the run in Shaping (`loam run stop`), and shows the next run.
    public func notNowDeskRun() async {
        guard let id = desk.runID, !desk.busy, !desk.drafting.contains(id) else { return }
        await deskAction(id) {
            _ = try await self.client.runStop(id)
            self.desk.shapeEdits[id] = nil
        }
    }

    /// Runs an action on the run, one at a time, then reads the runs again. A run that the action took from the
    /// queue gives its place to the next.
    private func deskAction(_ id: String, _ action: () async throws -> Void) async {
        desk.busy = true
        desk.error = nil
        defer { desk.busy = false }
        do {
            try await action()
        } catch {
            desk.error = Self.message(for: error)
            return
        }
        await reloadRuns()
    }

    /// After the runs change: the run of the desk reads its history again while it waits. A run that left the
    /// queue, by an action of the desk or by a tick, gives its place (`place` in the queue before the change) to
    /// the run that is now there. An empty desk shows the first run that comes.
    func followDeskQueue(from place: Int?) async {
        let queue = deskQueue
        if let id = desk.runID, queue.contains(where: { $0.id == id }) {
            await readRunStatus(id)
        } else if desk.runID != nil || !queue.isEmpty {
            await showDeskItem(queue.isEmpty ? nil : queue[min(place ?? 0, queue.count - 1)].id)
        }
    }

    /// Shows the run at the desk, and reads its work and its history.
    private func showDeskItem(_ id: String?) async {
        desk.runID = id
        desk.diff = nil
        desk.file = nil
        desk.error = nil
        runStatus = nil
        guard let id else { return }
        // A draft has no work to read yet.
        if runs.first(where: { $0.id == id })?.state == .shaping {
            await readRunStatus(id)
            return
        }
        do {
            let diff = try await client.runDiff(id)
            guard desk.runID == id else { return }
            desk.diff = diff
            desk.file = diff.files.first?.path
        } catch {
            guard desk.runID == id else { return }
            desk.error = Self.message(for: error)
        }
        await readRunStatus(id)
    }
}
