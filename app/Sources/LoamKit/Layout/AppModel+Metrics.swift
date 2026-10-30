import Foundation

/// Why Fix this could not draft a run that fixes the landed run.
public struct FixError: Equatable, Sendable {
    public var run: String
    public var message: String
}

/// The Metrics page and the fix of a landed run (TAS-176).
extension AppModel {
    /// Shows the Metrics page for the plot, or for every plot when it is nil, and reads the metrics.
    public func showMetrics(plot: String? = nil) async {
        if page != .metrics || metricsPlot != plot { (metrics, metricsError) = (nil, nil) }
        metricsPlot = plot
        page = .metrics
        await reloadMetrics()
    }

    /// Reads the metrics of the plot that the Metrics page shows. A failed read keeps the last metrics. With no
    /// metrics yet, `metricsError` says why.
    public func reloadMetrics() async {
        guard page == .metrics else { return }
        metricsReads += 1
        let (plot, read) = (metricsPlot, metricsReads)
        do {
            let got = try await client.runMetrics(plot: plot)
            guard page == .metrics, metricsPlot == plot, read == metricsReads else { return }
            (metrics, metricsError) = (got, nil)
        } catch {
            guard page == .metrics, metricsPlot == plot, read == metricsReads else { return }
            if metrics == nil { metricsError = Self.message(for: error) }
            report(error)
        }
    }

    /// Fix this, on the page of a landed run: Claude drafts a run that fixes it, from its issue and its repo, and the
    /// desk shows the draft. On a failure, `fixError` says why, and the page stays. While another run starts, it
    /// does nothing.
    public func fixRun(_ id: String) async {
        let shown = runStatus?.run.id == id ? runStatus?.run : nil
        guard !isStartingRun, let run = runs.first(where: { $0.id == id }) ?? shown, run.state == .landed else { return }
        fixError = nil
        if await !shapeRun(plot: run.plotID, draft: RunDraft(fixing: run)) {
            fixError = FixError(run: id, message: runStartError ?? "Loam could not draft the fix.")
        }
    }
}
