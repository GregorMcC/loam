import Foundation

/// A page that the well shows in place of the tabs and panes (ticket 203).
public enum AppPage: Equatable, Sendable {
    /// Today: the desk tiles, the line, and the runs of every plot.
    case today
    /// One run: its goal, its checks, its history, and its actions.
    case run(String)
    /// The intake of a plot: its open issues and map tickets (ticket 204).
    case intake(String)
}

extension AppModel {
    /// What Today shows, from the runs and the plots.
    public var today: TodayContent { TodayContent(runs: runs, plots: plots) }

    /// Reads the runs of every plot. A failed read keeps the last list. The run page reads its run
    /// again, so its history follows the gate.
    public func reloadRuns() async {
        guard let all = try? await client.runs() else { return }
        runs = all
        if case .run(let id) = page { await readRunStatus(id) }
    }

    /// `loam run tick`: ships the runs whose checks passed. When the tick moved a run, the runs are
    /// read again. A failed tick changes nothing: the next one tries again.
    public func tickRuns() async {
        guard let result = try? await client.runTick(), !result.runs.isEmpty else { return }
        await reloadRuns()
    }

    /// Runs a tick every `runTickInterval` while a run waits on GitHub. Nothing runs before this starts,
    /// so a model in a unit test never runs `loam`.
    func startRunTicks() {
        guard runTicks == nil else { return }
        runTicks = Task { [weak self] in
            while let self, (try? await Task.sleep(for: self.runTickInterval)) != nil {
                if runs.contains(where: \.waitsOnGitHub) { await tickRuns() }
            }
        }
    }

    /// Shows Today in the well.
    public func showToday() {
        page = .today
    }

    /// Shows the page of a run, and reads its history.
    public func openRun(_ id: String) async {
        if runStatus?.run.id != id { runStatus = nil }
        page = .run(id)
        await readRunStatus(id)
    }

    /// Closes the page, so the well shows the tabs and panes again.
    public func closePage() {
        page = nil
    }

    private func readRunStatus(_ id: String) async {
        do {
            let status = try await client.runStatus(id)
            guard page == .run(id) else { return }
            runStatus = status
        } catch {
            report(error)
        }
    }

    /// Opens a shell tab in the run's plot that attaches to its background session with
    /// `claude attach`. The tab is a plain shell: when you detach or the session ends, the shell
    /// command ends, and the background session goes on.
    public func watchRun(_ run: Run) {
        guard let short = run.shortSessionID, plots.contains(where: { $0.id == run.plotID }) else { return }
        activate(plot: run.plotID)
        var spec = newShellSpec(in: .plot(run.plotID), folder: run.folder)
        spec.command = PaneCommand.attach(shell: shell, sessionID: short)
        spec.title = run.title
        openTab(spec)
    }

    /// `loam run stop`: stops the background session of the run. The run is Cancelled.
    public func stopRun(_ id: String) async {
        do {
            _ = try await client.runStop(id)
            await reloadRuns()
        } catch {
            report(error)
        }
    }
}
