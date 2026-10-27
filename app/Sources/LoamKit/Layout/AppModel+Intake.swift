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
