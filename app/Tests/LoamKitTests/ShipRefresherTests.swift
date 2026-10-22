import Foundation
import Testing

@testable import LoamKit

/// A sleep that a test ends by hand: `release` wakes the sleeps of one length. A sleep that the
/// refresher cancels ends with a `CancellationError`, as `Task.sleep` does.
@MainActor
final class ManualSleep {
    private var waiters: [(id: Int, length: Duration, wake: CheckedContinuation<Void, Error>)] = []
    private var next = 0

    func sleep(_ length: Duration) async throws {
        let id = next
        next += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { wake.resume(throwing: CancellationError()); return }
                waiters.append((id, length, wake))
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).wake.resume(throwing: CancellationError())
    }

    /// The lengths of the sleeps that wait now.
    var lengths: [Duration] { waiters.map(\.length) }

    func count(_ length: Duration) -> Int { lengths.filter { $0 == length }.count }

    /// Wakes the sleeps of this length.
    func release(_ length: Duration) {
        let woken = waiters.filter { $0.length == length }
        waiters.removeAll { $0.length == length }
        for waiter in woken { waiter.wake.resume() }
    }

    /// Yields until `count` sleeps of this length wait. Fails the test after a second.
    func waiting(for length: Duration, count wanted: Int = 1) async {
        let deadline = Date().addingTimeInterval(1)
        while count(length) < wanted, Date() < deadline { await Task.yield() }
        #expect(count(length) >= wanted, "\(count(length)) sleeps of \(length) wait, not \(wanted)")
    }
}

/// The refreshes that a `ShipRefresher` ran. A refresh can wait until the test lets it end.
@MainActor
final class RefreshProbe {
    private(set) var started: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    /// While true, each refresh waits for `finishOne`.
    var holds = false

    func run(_ plot: String) async {
        started.append(plot)
        if holds { await withCheckedContinuation { held.append($0) } }
    }

    func finishOne() { if !held.isEmpty { held.removeFirst().resume() } }

    /// Yields until `count` refreshes started. Fails the test after a second.
    func waitForStarted(_ count: Int) async {
        let deadline = Date().addingTimeInterval(1)
        while started.count < count, Date() < deadline { await Task.yield() }
        #expect(started.count >= count, "\(started.count) refreshes started, not \(count)")
    }

    /// Yields many times, so a refresh that should not start has the time to start.
    func settle() async { for _ in 0..<50 { await Task.yield() } }
}

@MainActor
@Suite struct ShipRefresherTests {
    let sleep = ManualSleep()
    let probe = RefreshProbe()
    let refresher: ShipRefresher

    /// A refresher with no active plot and no other plot, so `start` runs no refresh. A test names the
    /// plots it needs.
    init() {
        let sleep = sleep
        refresher = ShipRefresher(sleep: { try await sleep.sleep($0) })
        refresher.run = { [probe] in await probe.run($0) }
    }

    private var window: Duration { refresher.timing.stopWindow }

    // MARK: Start and stop

    @Test func nothingRunsBeforeStart() async {
        refresher.activePlot = { "a" }
        await refresher.refresh("a")
        refresher.stopped(in: "a")
        await probe.settle()
        #expect(probe.started.isEmpty)
        #expect(sleep.lengths.isEmpty)
        #expect(!refresher.isRunning)
    }

    @Test func startRefreshesTheActivePlotThenTheOthersOneAfterTheOther() async {
        refresher.activePlot = { "a" }
        refresher.otherPlots = { ["b", "c"] }
        probe.holds = true
        refresher.start()
        await probe.waitForStarted(1)
        await probe.settle()
        #expect(probe.started == ["a"])
        probe.finishOne()
        await probe.waitForStarted(2)
        await probe.settle()
        #expect(probe.started == ["a", "b"])
        probe.finishOne()
        await probe.waitForStarted(3)
        #expect(probe.started == ["a", "b", "c"])
        probe.finishOne()
        refresher.stop()
    }

    @Test func startTwiceStartsTheLoopsOnce() async {
        refresher.start()
        refresher.start()
        await sleep.waiting(for: refresher.timing.activeInterval)
        await sleep.waiting(for: refresher.timing.otherInterval)
        await probe.settle()
        #expect(sleep.count(refresher.timing.activeInterval) == 1)
        #expect(sleep.count(refresher.timing.otherInterval) == 1)
        refresher.stop()
    }

    @Test func stopEndsTheWaitsAndTheLoops() async {
        refresher.start()
        refresher.stopped(in: "a")
        await sleep.waiting(for: window)
        await sleep.waiting(for: refresher.timing.activeInterval)
        refresher.stop()
        await probe.settle()
        #expect(!refresher.isRunning)
        #expect(sleep.lengths.isEmpty)
        #expect(probe.started.isEmpty)
    }

    // MARK: One at a time

    @Test func aRefreshRunsOnePerPlotAtATime() async {
        refresher.start()
        probe.holds = true
        let first = Task { await refresher.refresh("a") }
        await probe.waitForStarted(1)
        // Five triggers during the refresh make one more refresh, not five.
        let more = (0..<5).map { _ in Task { await refresher.refresh("a") } }
        await probe.settle()
        #expect(probe.started == ["a"])
        probe.finishOne()
        await probe.waitForStarted(2)
        probe.finishOne()
        await first.value
        for task in more { await task.value }
        await probe.settle()
        #expect(probe.started == ["a", "a"])
        refresher.stop()
    }

    @Test func aPlotIsRefreshingWhileItsRefreshRuns() async {
        refresher.start()
        #expect(!refresher.isRefreshing("a"))
        probe.holds = true
        let running = Task { await refresher.refresh("a") }
        await probe.waitForStarted(1)
        #expect(refresher.isRefreshing("a"))
        #expect(!refresher.isRefreshing("b"), "the refresh of another plot")
        probe.finishOne()
        await running.value
        #expect(!refresher.isRefreshing("a"))
        refresher.stop()
    }

    @Test func aTriggerAfterTheRefreshEndedRunsANewOne() async {
        refresher.start()
        await refresher.refresh("a")
        await refresher.refresh("a")
        #expect(probe.started == ["a", "a"])
        refresher.stop()
    }

    @Test func differentPlotsRefreshAtTheSameTime() async {
        refresher.start()
        probe.holds = true
        let a = Task { await refresher.refresh("a") }
        let b = Task { await refresher.refresh("b") }
        await probe.waitForStarted(2)
        #expect(Set(probe.started) == ["a", "b"])
        probe.finishOne()
        probe.finishOne()
        await a.value
        await b.value
        refresher.stop()
    }

    // MARK: Stop events

    @Test func stopEventsOfOnePlotJoinOneRefresh() async {
        refresher.start()
        for _ in 0..<4 { refresher.stopped(in: "a") }
        await sleep.waiting(for: window)
        await probe.settle()
        #expect(sleep.count(window) == 1)
        #expect(probe.started.isEmpty)
        sleep.release(window)
        await probe.waitForStarted(1)
        await probe.settle()
        #expect(probe.started == ["a"])
        refresher.stop()
    }

    @Test func aStopEventAfterTheWindowStartsANewWindow() async {
        refresher.start()
        refresher.stopped(in: "a")
        await sleep.waiting(for: window)
        sleep.release(window)
        await probe.waitForStarted(1)
        await probe.settle()
        refresher.stopped(in: "a")
        await sleep.waiting(for: window)
        sleep.release(window)
        await probe.waitForStarted(2)
        #expect(probe.started == ["a", "a"])
        refresher.stop()
    }

    @Test func eachPlotHasItsOwnWindow() async {
        refresher.start()
        refresher.stopped(in: "a")
        refresher.stopped(in: "b")
        await sleep.waiting(for: window, count: 2)
        sleep.release(window)
        await probe.waitForStarted(2)
        #expect(Set(probe.started) == ["a", "b"])
        refresher.stop()
    }

    @Test func theTimingIsFiveSecondsSixtySecondsAndFiveMinutes() {
        #expect(ShipRefresher.Timing().stopWindow == .seconds(5))
        #expect(ShipRefresher.Timing().activeInterval == .seconds(60))
        #expect(ShipRefresher.Timing().otherInterval == .seconds(300))
    }

    // MARK: Archived plots

    @Test func anArchivedPlotGetsNoRefreshAndNoWait() async {
        refresher.activePlot = { "a" }
        refresher.otherPlots = { ["b", "c"] }
        refresher.isRefreshable = { $0 != "b" }
        refresher.start()
        await probe.waitForStarted(2)
        await probe.settle()
        #expect(probe.started == ["a", "c"])
        await refresher.refresh("b")
        refresher.stopped(in: "b")
        await probe.settle()
        #expect(sleep.count(window) == 0)
        #expect(probe.started == ["a", "c"])
        refresher.stop()
    }

    @Test func aPlotThatIsArchivedDuringTheWaitGetsNoRefresh() async {
        var archived = false
        refresher.isRefreshable = { _ in !archived }
        refresher.start()
        refresher.stopped(in: "a")
        await sleep.waiting(for: window)
        archived = true
        sleep.release(window)
        await probe.settle()
        #expect(probe.started.isEmpty)
        refresher.stop()
    }

    // MARK: Timers

    @Test func theActivePlotRefreshesEveryIntervalWhileLoamIsFrontmost() async {
        var frontmost = true
        refresher.activePlot = { "a" }
        refresher.isFrontmost = { frontmost }
        refresher.start()
        await probe.waitForStarted(1)
        await sleep.waiting(for: refresher.timing.activeInterval)
        sleep.release(refresher.timing.activeInterval)
        await probe.waitForStarted(2)
        #expect(probe.started == ["a", "a"])
        // Another app is in front: the tick passes and nothing runs.
        frontmost = false
        await sleep.waiting(for: refresher.timing.activeInterval)
        sleep.release(refresher.timing.activeInterval)
        await sleep.waiting(for: refresher.timing.activeInterval)
        await probe.settle()
        #expect(probe.started == ["a", "a"])
        refresher.stop()
    }

    @Test func theOtherPlotsRefreshEveryOtherIntervalOneAfterTheOther() async {
        refresher.otherPlots = { ["b", "c"] }
        refresher.start()
        await probe.waitForStarted(2)
        await sleep.waiting(for: refresher.timing.otherInterval)
        sleep.release(refresher.timing.otherInterval)
        await probe.waitForStarted(4)
        #expect(probe.started == ["b", "c", "b", "c"])
        refresher.stop()
    }

    @Test func withoutAnActivePlotTheActiveTickRunsNothing() async {
        refresher.start()
        await sleep.waiting(for: refresher.timing.activeInterval)
        sleep.release(refresher.timing.activeInterval)
        await sleep.waiting(for: refresher.timing.activeInterval)
        await probe.settle()
        #expect(probe.started.isEmpty)
        refresher.stop()
    }

    @Test func aChangedTimingAppliesToTheNextSleep() async {
        refresher.timing.activeInterval = .seconds(3600)
        refresher.start()
        await sleep.waiting(for: .seconds(3600))
        refresher.stop()
    }
}
