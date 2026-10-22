import Foundation

/// When the app asks GitHub for the ship state of the worktrees (ticket 108). Each ask is one
/// `loam worktree list <plot> --refresh`, which `run` does. This type decides when, and how many at a
/// time. The triggers:
///
/// - You open a plot (`AppModel` calls `refresh`).
/// - A seeded session in the plot ends a turn (`stopped(in:)`). It waits `stopWindow`, and the Stop
///   events of one plot in that time make one refresh.
/// - Every `activeInterval` for the active plot while Loam is the front app. Every `otherInterval`
///   for the other plots, one after the other.
///
/// One refresh runs at a time for each plot. A trigger while it runs makes one more refresh after
/// it, not one for each trigger. A plot that `isRefreshable` rejects (an archived plot) gets none.
/// Nothing runs before `start()`, so a model in a unit test never runs `loam`.
@MainActor
public final class ShipRefresher {
    public struct Timing: Equatable, Sendable {
        /// The wait before the refresh that follows a Stop event.
        public var stopWindow: Duration = .seconds(5)
        /// The time between the refreshes of the active plot.
        public var activeInterval: Duration = .seconds(60)
        /// The time between the refreshes of the other plots.
        public var otherInterval: Duration = .seconds(300)

        public init() {}
    }

    /// Read at the start of each wait, so a change applies to the next one.
    public var timing = Timing()
    /// Runs one refresh of the plot and applies the answer. `AppModel` sets it.
    public var run: @MainActor (String) async -> Void = { _ in }
    /// False for a plot that must get no refresh, such as an archived plot.
    public var isRefreshable: @MainActor (String) -> Bool = { _ in true }
    /// The plot that you look at, or nil in Home.
    public var activePlot: @MainActor () -> String? = { nil }
    /// The plots that are not the active plot and are refreshable, in sidebar order.
    public var otherPlots: @MainActor () -> [String] = { [] }
    /// True while Loam is the front app. The active plot refreshes on its timer only then.
    public var isFrontmost: @MainActor () -> Bool = { true }

    public private(set) var isRunning = false

    private let sleep: @Sendable (Duration) async throws -> Void
    /// The refresh of each plot that runs now.
    private var runs: [String: Task<Void, Never>] = [:]
    /// The plots that asked for one more refresh while theirs ran.
    private var again: Set<String> = []
    /// The Stop windows that wait now, one for each plot.
    private var windows: [String: Task<Void, Never>] = [:]
    private var timers: [Task<Void, Never>] = []

    /// `sleep` is the clock. Tests pass one that they end by hand.
    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    // MARK: Start and stop

    /// Starts the two timers, and refreshes the active plot and then the others, one after the other.
    /// Does nothing when it runs already.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        timers = [
            Task { [weak self] in
                while let self, await self.wait(self.timing.activeInterval) {
                    if let plot = activePlot(), isFrontmost() { await refresh(plot) }
                }
            },
            Task { [weak self] in
                while let self, await self.wait(self.timing.otherInterval) {
                    await refreshOthers()
                }
            },
        ]
        Task { [weak self] in
            guard let self else { return }
            if let plot = activePlot() { await refresh(plot) }
            await refreshOthers()
        }
    }

    /// Ends the timers and the Stop windows. A refresh that runs now ends by itself.
    public func stop() {
        isRunning = false
        for task in timers + Array(windows.values) { task.cancel() }
        timers = []
        windows = [:]
    }

    // MARK: Refresh

    /// Refreshes the plot, or asks for one more refresh after the one that runs. Returns when the plot
    /// has none left to run. Does nothing before `start()` and for a plot that is not refreshable.
    public func refresh(_ plot: String) async {
        guard isRunning, isRefreshable(plot) else { return }
        if let running = runs[plot] {
            again.insert(plot)
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                again.remove(plot)
                await run(plot)
            } while again.contains(plot) && isRunning && isRefreshable(plot)
            again.remove(plot)
            runs[plot] = nil
        }
        runs[plot] = task
        await task.value
    }

    /// A seeded session in the plot ended a turn. The refresh comes after `stopWindow`, and the Stop
    /// events of the plot in that time join it.
    public func stopped(in plot: String) {
        guard isRunning, isRefreshable(plot), windows[plot] == nil else { return }
        windows[plot] = Task { [weak self] in
            guard let self, await wait(timing.stopWindow) else { return }
            windows[plot] = nil
            await refresh(plot)
        }
    }

    // MARK: Plumbing

    /// Waits `length`. False when the wait was cancelled.
    private func wait(_ length: Duration) async -> Bool {
        do {
            try await sleep(length)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func refreshOthers() async {
        for plot in otherPlots() { await refresh(plot) }
    }
}
