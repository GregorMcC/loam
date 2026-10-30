import Foundation

/// A page that the well shows in place of the tabs and panes (ticket 203).
public enum AppPage: Equatable, Sendable {
    /// Today: the desk tiles, the line, and the runs of every plot.
    case today
    /// One run: its goal, its checks, its history, and its actions.
    case run(String)
    /// The intake of a plot: its open issues and map tickets (ticket 204).
    case intake(String)
    /// The recurring runs of a plot (ticket 208).
    case recurring(String)
    /// The desk: the runs that wait for you, one at a time (ticket 207). `AppModel.desk` says which.
    case desk
    /// The run metrics: where the time of the runs goes, from approve to landed (TAS-176). `AppModel.metricsPlot`
    /// says which plot, or every plot.
    case metrics
}

extension AppModel {
    /// Reads the runs of every plot. A failed read keeps the last list. The run page reads its run
    /// again, so its history follows the gate. The desk follows its queue.
    public func reloadRuns() async {
        guard let all = try? await client.runs() else { return }
        let place = deskQueue.firstIndex { $0.id == desk.runID }
        let changed = all != runs
        runs = all
        if await openNewDraft() { return }
        if case .run(let id) = page { await readRunStatus(id) }
        if page == .today { await readAwayEvents() }
        if page == .desk { await followDeskQueue(from: place) }
        // A full read of the history, so only when a run changed.
        if page == .metrics, changed { await reloadMetrics() }
    }

    /// `loam run tick`: ships the runs whose checks passed. When the tick moved a run, the runs are
    /// read again. A failed tick changes nothing: the next one tries again.
    public func tickRuns() async {
        guard let result = try? await client.runTick(), !result.runs.isEmpty else { return }
        await reloadRuns()
    }

    /// Runs a tick every `runTickInterval` while a run waits on GitHub, or while a recurring run waits for its time
    /// and launchd does not tick. Nothing runs before this starts,
    /// so a model in a unit test never runs `loam`.
    func startRunTicks() {
        guard runTicks == nil else { return }
        runTicks = Task { [weak self] in
            while let self, (try? await Task.sleep(for: self.runTickInterval)) != nil {
                if tickStatus == nil { await readTickStatus(lookForRecurring: true) }
                // loam tick ships the runs too, so one tick does both.
                if appTicksRecurring {
                    await tickRecurring()
                } else if runs.contains(where: \.waitsOnGitHub) {
                    await tickRuns()
                }
            }
        }
    }

    /// Shows Today in the well.
    public func showToday() {
        page = .today
    }

    /// Opens a run that waits for you where you decide on it: the desk for a run in its queue, else the run page.
    public func openWaitingRun(_ id: String) async {
        if deskQueue.contains(where: { $0.id == id }) {
            await openDesk(id)
        } else {
            await openRun(id)
        }
    }

    /// Shows the page of a run, and reads its history.
    public func openRun(_ id: String) async {
        // You approve a draft at the desk.
        if runs.first(where: { $0.id == id })?.state == .shaping {
            await openDesk(id)
            return
        }
        if runStatus?.run.id != id { runStatus = nil }
        fixError = nil
        page = .run(id)
        await readRunStatus(id)
    }

    /// Closes the page, so the well shows the tabs and panes again.
    public func closePage() {
        page = nil
    }

    func readRunStatus(_ id: String) async {
        do {
            let status = try await client.runStatus(id)
            guard page == .run(id) || (page == .desk && desk.runID == id) else { return }
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
