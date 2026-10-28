import Foundation

extension AppModel {
    /// Shows the intake of the plot in the well, and reads it. With no plot, it is the active plot, or the first.
    public func showIntake(plot: String? = nil) async {
        guard let id = plot ?? workspace.activePlotID ?? plots.first?.id else { return }
        if intake?.plotID != id { intake = nil }
        runStartError = nil
        page = .intake(id)
        await reloadIntake()
    }

    /// Reads the intake of the plot that the Intake page shows. A failed read keeps the last list.
    public func reloadIntake() async {
        guard case .intake(let id) = page else { return }
        do {
            let list = try await client.intake(plot: id)
            guard page == .intake(id) else { return }
            intake = list
        } catch {
            report(error)
        }
    }

    /// True when the last run did not start because the setup command of the repo is new or changed. The page then
    /// offers to approve it, since the core names the command in `runStartError`.
    public var runStartNeedsSetupApproval: Bool {
        runStartError?.contains("--approve-setup") == true
    }

    /// `loam run shape` from the Intake page: Claude drafts the run, and the desk shows the draft. The desk opens
    /// on the run as soon as the core records it, and shows each step of the draft as Claude takes it. On success it
    /// returns true. On a failure, `runStartError` says why, and the page stays. A draft that Claude could not make
    /// is no failure: the desk shows the run with the reason.
    public func shapeRun(plot: String, draft: RunDraft) async -> Bool {
        guard !isStartingRun else { return false }
        isStartingRun = true
        runStartError = nil
        pendingShape = PendingShape(plot: plot, before: Set(runs.map(\.id)))
        defer {
            isStartingRun = false
            pendingShape = nil
        }
        do {
            let result = try await client.runShape(plot: plot, draft: draft)
            await reloadRuns()
            // When the desk opened on the run while Claude drafted, you may have left it since: it stays left.
            if pendingShape != nil { await openDesk(result.run.id) }
            return true
        } catch {
            runStartError = Self.message(for: error)
            return false
        }
    }

    /// The bar of the Intake page: `loam run shape` or `loam run start` for each draft, one after another. The page
    /// stays, and each row shows its run. It stops at the first failure, and `runStartError` says why. It returns
    /// how many runs it made. A chore that waits for its setup approval gets it when `runStartNeedsSetupApproval`.
    public func startIntakeBatch(plot: String, drafts: [RunDraft], shape: Bool) async -> Int {
        guard !isStartingRun else { return 0 }
        let approve = runStartNeedsSetupApproval
        isStartingRun = true
        runStartError = nil
        var made = 0
        for var draft in drafts {
            do {
                if shape {
                    _ = try await client.runShape(plot: plot, draft: draft)
                } else {
                    draft.approveSetup = approve
                    _ = try await client.runStart(plot: plot, draft: draft)
                }
                made += 1
            } catch {
                runStartError = Self.message(for: error)
                break
            }
        }
        isStartingRun = false
        await reloadRuns()
        await reloadIntake()
        return made
    }

    /// The rules of the plot, which every run reads and must pass, for the Intake page. A failed read gives none.
    public func intakeRules(plot: String) async -> [Rule] {
        (try? await client.ruleList(plot: plot)) ?? []
    }

    /// True when a run moves its Linear issue to In Progress as it starts (`loam linear updates`). Nil when the read
    /// fails.
    public func linearMovesToInProgress() async -> Bool? {
        try? await client.linearUpdates().inProgress
    }

    /// Reads the model and the effort that a run of the plot gets when it names none. A failed read leaves none.
    public func readRunDefaults(plot: String) async {
        runDefaults = try? await client.runDefaults(plot: plot)
    }

    /// Sets the model and the effort that a run of the plot gets when it names none. "" clears one.
    public func setRunDefaults(plot: String, model: String, effort: String) async {
        do {
            runDefaults = try await client.setRunDefaults(plot: plot, model: model, effort: effort)
            runDefaultsError = nil
        } catch {
            runDefaultsError = Self.message(for: error)
        }
    }

    /// A shape in progress: its plot, and the runs that were there before it.
    struct PendingShape: Equatable {
        var plot: String
        var before: Set<String>
    }

    /// Opens the desk on the run of the pending shape when it is in the runs. It returns true when it did.
    func openNewDraft() async -> Bool {
        guard let pending = pendingShape,
              let run = runs.first(where: { $0.plotID == pending.plot && $0.state == .shaping && !pending.before.contains($0.id) })
        else { return false }
        pendingShape = nil
        await openDesk(run.id)
        return true
    }

    /// Reads the bases of a repo of the plot for the start form (TAS-21): the repo with the ID, or the main repo
    /// for nil. A plot with no such repo, or a failed read, has no bases, and the form shows no Base picker.
    public func readRunBases(plot: String, repo: String? = nil) async {
        guard let checkout = repoCheckouts[plot]?.first(where: { repo == nil ? $0.isMain : $0.id == repo }) else {
            runBases = nil
            return
        }
        await readRunBases(plot: plot, repo: checkout.id, branch: checkout.branch)
    }

    func readRunBases(plot: String, repo: String, branch: String?) async {
        // The name is only for the dry run: no branch or worktree is made.
        let check = try? await client.worktreeCheck(plot: plot, repo: repo, name: "loam-run-base")
        runBases = check.map {
            var bases = RunBases(plot: plot, check: $0, branch: branch)
            bases.repo = repo
            return bases
        }
    }

    /// `loam run start` from the Intake page. On success the run page shows the new run, and it returns true. On a
    /// failure, `runStartError` says why, and the page stays.
    public func startRun(plot: String, draft: RunDraft) async -> Bool {
        guard !isStartingRun else { return false }
        isStartingRun = true
        runStartError = nil
        defer { isStartingRun = false }
        do {
            let result = try await client.runStart(plot: plot, draft: draft)
            await reloadRuns()
            await openRun(result.run.id)
            return true
        } catch {
            runStartError = Self.message(for: error)
            return false
        }
    }
}

extension AppModel {
    /// The other runs of the group of the run, oldest first (TAS-37). A run alone has none.
    public func groupRuns(of run: Run) -> [Run] {
        guard !run.groupID.isEmpty else { return [] }
        return runs.filter { $0.groupID == run.groupID && $0.id != run.id }.sorted { $0.createdAt < $1.createdAt }
    }

    /// The folder name of the repo that the run works in, or "" when the plot has no such repo.
    public func repoName(of run: Run) -> String {
        guard let repo = run.shape?.repo, !repo.isEmpty,
              let checkout = repoCheckouts[run.plotID]?.first(where: { $0.id == repo }) else { return "" }
        return URL(fileURLWithPath: checkout.path).lastPathComponent
    }
}
