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

    /// `loam run shape` from the Intake page: Claude drafts the run, and the desk shows the draft. On success it
    /// returns true. On a failure, `runStartError` says why, and the page stays. A draft that Claude could not make
    /// is no failure: the desk shows the run with the reason.
    public func shapeRun(plot: String, draft: RunDraft) async -> Bool {
        guard !isStartingRun else { return false }
        isStartingRun = true
        runStartError = nil
        defer { isStartingRun = false }
        do {
            let result = try await client.runShape(plot: plot, draft: draft)
            await reloadRuns()
            await openDesk(result.run.id)
            return true
        } catch {
            runStartError = Self.message(for: error)
            return false
        }
    }

    /// Reads the bases of the main repo of the plot for the start form (TAS-21). A plot with no main repo, or a
    /// failed read, has no bases, and the form shows no Base picker.
    public func readRunBases(plot: String) async {
        guard let repo = repoCheckouts[plot]?.first(where: \.isMain) else {
            runBases = nil
            return
        }
        await readRunBases(plot: plot, repo: repo.id, branch: repo.branch)
    }

    func readRunBases(plot: String, repo: String, branch: String?) async {
        // The name is only for the dry run: no branch or worktree is made.
        let check = try? await client.worktreeCheck(plot: plot, repo: repo, name: "loam-run-base")
        runBases = check.map { RunBases(plot: plot, check: $0, branch: branch) }
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
