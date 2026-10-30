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

    /// The file after the one that the desk shows, in the order to read them, round to the first (TAS-49). Nil when
    /// the work has fewer than 2 files.
    public var nextDeskFile: String? {
        let files = DeskContent.readOrder(desk.diff?.files ?? [], notes: deskRun?.notes).map(\.file.path)
        guard files.count > 1 else { return nil }
        let current = files.firstIndex { $0 == desk.file } ?? files.count - 1
        return files[(current + 1) % files.count]
    }

    /// ]: shows the next file. It reads the file that the desk shows now, so a key that SwiftUI keeps from an earlier
    /// render still moves on.
    public func showNextDeskFile() {
        if let next = nextDeskFile { desk.file = next }
    }

    /// Keeps the worktree after the merge, or removes it.
    public func setDeskKeepWorktree(_ keep: Bool) {
        desk.keepWorktree = keep
    }

    /// True when the merge moves the Linear issue of the run to Done: your choice, else the Done switch.
    public var deskLinearDone: Bool { desk.linearDone ?? desk.linearUpdates?.done ?? true }

    /// Moves the Linear issue to Done at the merge, or leaves it where it is.
    public func setDeskLinearDone(_ done: Bool) {
        desk.linearDone = done
    }

    /// Moves Where it stands of the plot on to the text of the ship notes at the merge, or leaves it.
    public func setDeskMoveWhereItStands(_ move: Bool) {
        desk.moveWhereItStands = move
    }

    /// The worktree of the run in Shaping: the worktree that it has, else the name that the core gives it when
    /// you approve it.
    public func deskWorktreeName(_ run: Run) -> String {
        let worktrees = (worktrees[run.plotID] ?? []).map(\.worktree)
        if !run.worktreeID.isEmpty, let worktree = worktrees.first(where: { $0.id == run.worktreeID }) {
            return worktree.name
        }
        return RunWorktreeName.name(title: run.title, key: RunWorktreeName.key(of: run), taken: Set(worktrees.map(\.name)))
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

    /// Sends your notes on the run back to its session (`loam run send-back`), and shows the next run. A note like
    /// one that you sent back on another run of the plot offers a rule.
    public func sendBackDeskNotes() async {
        guard let id = desk.runID, !desk.busy, !desk.currentNotes.isEmpty else { return }
        let notes = desk.currentNotes.map(\.argument)
        await deskAction(id) {
            let result = try await self.client.runSendBack(id, notes: notes)
            self.desk.notes[id] = nil
            if let offer = result.ruleOffer { self.desk.ruleOffer = DeskRuleOffer(plotID: result.run.plotID, offer: offer) }
        }
    }

    /// Opens or closes the comments of the review row.
    public func toggleDeskReview() {
        desk.reviewOpen.toggle()
    }

    /// Sends the review of the PR back to the session of the run (`loam run send-review`), and shows the next run.
    /// The core sends the threads and the reviews with the filter for the text of readers, and builds the prompt.
    public func sendBackDeskReview() async {
        guard let id = desk.runID, !desk.busy, desk.review?.canSendBack == true else { return }
        await deskAction(id) {
            _ = try await self.client.runSendReview(id)
        }
    }

    /// Reads the review of the PR of a ready run (`loam run send-review --dry-run`). A run in another state, or a run
    /// with no PR, has no review row. A failed read says why in the row, and the Merge button stays.
    func readDeskReview(_ run: Run) async {
        guard run.state == .ready, run.pr != nil else {
            desk.review = nil
            desk.reviewError = nil
            desk.reviewStamp = nil
            return
        }
        do {
            let review = DeskReview(try await client.runSendReview(run.id, dryRun: true))
            guard desk.runID == run.id else { return }
            desk.review = review
            desk.reviewError = nil
        } catch {
            guard desk.runID == run.id else { return }
            desk.review = nil
            desk.reviewError = Self.message(for: error)
        }
        desk.reviewStamp = run.updatedAt
    }

    /// Reads the review of the run that the desk shows again, when a ship refresh asked GitHub about its plot. A review
    /// changes on GitHub with no change to the run, so the run row alone does not tell the desk.
    func rereadDeskReview(plot: String) async {
        guard page == .desk, let run = deskRun, run.plotID == plot else { return }
        await readDeskReview(run)
    }

    /// Merges the PR of the run (`loam run land`), with the head of the diff that you read, and shows the
    /// next run. A merge that the core refuses keeps the run, and `desk.error` says why. The core keeps a
    /// worktree that has open panes, so the desk closes none. The merge can remove the worktree, so the
    /// worktrees are read again, and the toast says what the merge did, as at the Land sheet. The merge moves
    /// the Linear issue to Done and Where it stands on, as When you merge says.
    public func landDeskRun() async {
        guard let id = desk.runID, !desk.busy else { return }
        let head = desk.diff?.head
        let keep = desk.keepWorktree
        let linearDone = deskRun?.source?.kind != "linear" || deskLinearDone
        let whereItStands = desk.moveWhereItStands && deskRun?.notes?.whereItStands.isEmpty == false
        let panes = openPaneFolders + savedPaneFolders()
        var landed: RunLandResult?
        await deskAction(id) {
            landed = try await self.client.runLand(id, head: head, keepWorktree: keep, linearDone: linearDone,
                                                   whereItStands: whereItStands, openPanes: panes)
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

    /// Keeps or drops a follow-up of the draft. A dropped follow-up files no issue when you approve the run.
    public func setDeskFollowUp(_ index: Int, kept: Bool) {
        editDeskShape { edit, run in
            guard run.shape?.followUps.indices.contains(index) == true else { return }
            if kept { edit.droppedFollowUps.remove(index) } else { edit.droppedFollowUps.insert(index) }
        }
    }

    private func editDeskShape(_ change: (inout ShapeEdit, Run) -> Void) {
        guard let run = deskRun, run.state == .shaping else { return }
        var edit = desk.shapeEdits[run.id] ?? ShapeEdit()
        change(&edit, run)
        desk.shapeEdits[run.id] = edit.isEmpty ? nil : edit
    }

    /// Starts the run with its draft and your edits (`loam run approve`), and shows the next run. The desk shows
    /// the setup command of the repo, so this approval approves it, as it does after the core refused a new one.
    public func approveDeskRun() async {
        guard let id = desk.runID, !desk.busy, !desk.drafting.contains(id) else { return }
        let edit = desk.currentEdit
        let approveSetup = desk.needsSetupApproval || desk.setup != nil
        await deskAction(id) {
            let started = try await self.client.runApprove(id, goal: edit.goal, checks: edit.checks, answers: edit.answers,
                                                           dropFollowUps: edit.droppedFollowUps, approveSetup: approveSetup)
            self.desk.shapeEdits[id] = nil
            // The run starts when a follow-up fails to file, so the toast is the one place that says so.
            let failed = started.run.shape?.followUps.filter { $0.error != nil }.count ?? 0
            if failed > 0 {
                self.onToast?("The run started. Loam could not file \(failed == 1 ? "1 follow-up" : "\(failed) follow-ups"). "
                              + "The run events say why.", .notice)
            }
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
        // A new draft has new follow-ups, so a drop of the old list would land on another one.
        if var edit = desk.shapeEdits[id] {
            edit.droppedFollowUps = []
            desk.shapeEdits[id] = edit.isEmpty ? nil : edit
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
        if let id = desk.runID, let run = queue.first(where: { $0.id == id }) {
            await readRunStatus(id)
            if run.updatedAt != desk.reviewStamp { await readDeskReview(run) }
        } else if desk.runID != nil || !queue.isEmpty {
            await showDeskItem(queue.isEmpty ? nil : queue[min(place ?? 0, queue.count - 1)].id)
        }
    }

    /// Shows the run at the desk, and reads its work and its history.
    private func showDeskItem(_ id: String?) async {
        desk.runID = id
        // The desk place of the history keeps the run that the desk shows.
        recordPlace()
        desk.diff = nil
        desk.file = nil
        desk.error = nil
        desk.rules = []
        desk.setup = nil
        desk.recurringTitle = nil
        desk.linearDone = nil
        desk.moveWhereItStands = true
        desk.review = nil
        desk.reviewError = nil
        desk.reviewStamp = nil
        desk.reviewOpen = false
        runStatus = nil
        guard let id else { return }
        // A draft has no work to read yet. The rules of its plot join its checks.
        if let run = runs.first(where: { $0.id == id }), run.state == .shaping {
            await readRunStatus(id)
            await readDeskRules(plot: run.plotID)
            await readDeskApproval(run)
            return
        }
        do {
            let diff = try await client.runDiff(id)
            guard desk.runID == id else { return }
            desk.diff = diff
            // The ship notes say which file to read first.
            let notes = runs.first { $0.id == id }?.notes
            desk.file = DeskContent.readOrder(diff.files, notes: notes).first?.file.path
        } catch {
            guard desk.runID == id else { return }
            desk.error = Self.message(for: error)
        }
        await readRunStatus(id)
        if let run = runs.first(where: { $0.id == id }) {
            await readDeskReview(run)
            if run.source?.kind == "linear" { await readDeskLinearUpdates() }
        }
    }

    /// Reads what an approval of the run does: the setup command of its repo, the run limits, the Linear updates
    /// for a run from Linear, and the recurring run that shaped it. A failed read shows nothing.
    private func readDeskApproval(_ run: Run) async {
        if let plot = try? await client.show(plot: run.plotID), desk.runID == run.id {
            let repo = run.shape?.repo ?? ""
            let setup = (repo.isEmpty ? plot.repos.first(where: \.main) : plot.repos.first { $0.id == repo })?.setup ?? ""
            desk.setup = setup.isEmpty ? nil : setup
        }
        if let limits = try? await client.runLimits() { desk.limits = limits }
        if run.source?.kind == "linear" { await readDeskLinearUpdates() }
        if let source = run.source, source.kind == "recurring",
           let recurring = try? await client.recurringList(plot: run.plotID), desk.runID == run.id {
            desk.recurringTitle = recurring.first { $0.id == source.key }?.title
        }
    }

    private func readDeskLinearUpdates() async {
        if let updates = try? await client.linearUpdates() { desk.linearUpdates = updates }
    }
}
