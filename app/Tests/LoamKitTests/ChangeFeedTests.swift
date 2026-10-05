import Foundation
import Testing
@testable import LoamKit

private func change(_ id: Int) -> Change {
    Change(id: id, plotID: "p", at: "t", actor: Actor(kind: .cli), entries: [], undoOf: nil)
}

/// Records each fetch and serves changes with an ID above `since`.
private actor FakeLog {
    var all: [Change]
    var sinceCalls: [Int?] = []
    var failNext = false
    init(_ ids: [Int]) { all = ids.map(change) }
    func add(_ id: Int) { all.append(change(id)) }
    func fail() { failNext = true }
    func fetch(_ since: Int?) throws -> [Change] {
        sinceCalls.append(since)
        if failNext { failNext = false; throw LoamError.failed(message: "boom") }
        return all.filter { $0.id > (since ?? 0) }
    }
    func calls() -> [Int?] { sinceCalls }
}

private func makeFeed(_ log: FakeLog, after: Int?, debounce: Duration = .milliseconds(80))
    -> (ChangeFeed, AsyncStream<Void>.Continuation)
{
    let (triggers, tc) = AsyncStream<Void>.makeStream()
    let feed = ChangeFeed(fetch: { try await log.fetch($0) }, triggers: triggers, debounce: debounce, after: after)
    return (feed, tc)
}

private func next(_ it: inout AsyncStream<FeedUpdate>.Iterator) async -> FeedUpdate? {
    await it.next()
}

/// Skips `.unchanged`: a stray file event can start a poll before the change exists.
private func nextChanges(_ it: inout AsyncStream<FeedUpdate>.Iterator) async -> FeedUpdate? {
    while let update = await it.next() {
        if update != .unchanged { return update }
    }
    return nil
}

@Suite struct ChangeFeedTests {
    @Test func aBurstOfEventsMakesOnePoll() async throws {
        let log = FakeLog([1, 2])
        let (feed, triggers) = makeFeed(log, after: 2)
        var it = feed.updates().makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(100))  // the start poll runs
        await log.add(3)
        for _ in 0..<10 {
            triggers.yield()
            try await Task.sleep(for: .milliseconds(10))  // shorter than the debounce
        }
        let update = await next(&it)
        #expect(update == .changes([change(3)]))
        // One start poll, then exactly one poll for the burst.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await log.calls() == [2, 2])
        triggers.finish()
    }

    @Test func cursorAdvancesToTheHighestID() async throws {
        let log = FakeLog([1])
        let (feed, triggers) = makeFeed(log, after: 1)
        var it = feed.updates().makeAsyncIterator()
        await log.add(2)
        triggers.yield()
        #expect(await next(&it) == .changes([change(2)]))
        await log.add(3)
        triggers.yield()
        #expect(await next(&it) == .changes([change(3)]))
        #expect(await log.calls().suffix(2) == [1, 2])
        triggers.finish()
    }

    @Test func aTriggerWithNoNewChangesPublishesUnchanged() async throws {
        let log = FakeLog([1])
        let (feed, triggers) = makeFeed(log, after: 1)
        var it = feed.updates().makeAsyncIterator()
        triggers.yield()
        #expect(await next(&it) == .unchanged)  // the start poll published nothing
        triggers.finish()
        #expect(await next(&it) == nil)
    }

    @Test func missingCursorBaselinesSilently() async throws {
        let log = FakeLog([1, 2, 3])
        let (feed, triggers) = makeFeed(log, after: nil)
        var it = feed.updates().makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(100))
        await log.add(4)
        triggers.yield()
        #expect(await next(&it) == .changes([change(4)]))
        triggers.finish()
    }

    @Test func failureIsPublishedAndTheFeedKeepsGoing() async throws {
        let log = FakeLog([1])
        let (feed, triggers) = makeFeed(log, after: 1)
        var it = feed.updates().makeAsyncIterator()
        await log.fail()
        triggers.yield()
        #expect(await next(&it) == .failure(.failed(message: "boom")))
        await log.add(2)
        triggers.yield()
        #expect(await next(&it) == .changes([change(2)]))
        triggers.finish()
    }

    @Test func realFileEventsDriveTheFeed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loam-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = FakeLog([1])
        let feed = ChangeFeed(
            fetch: { try await log.fetch($0) },
            triggers: DirectoryWatcher.events(at: dir), debounce: .milliseconds(50), after: 1)
        var it = feed.updates().makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(400))  // let FSEvents start
        await log.add(2)
        try Data("x".utf8).write(to: dir.appendingPathComponent("store.db"))
        #expect(await nextChanges(&it) == .changes([change(2)]))
    }

    @Test func shmEventsAreIgnored() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loam-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Let the folder's own create event pass before the watch starts. Under
        // load, FSEvents can deliver it after the stream opens.
        try await Task.sleep(for: .milliseconds(1000))
        let stream = DirectoryWatcher.events(at: dir)
        let reader = Task { () -> Bool in
            var it = stream.makeAsyncIterator()
            return await it.next() != nil
        }
        try await Task.sleep(for: .milliseconds(400))
        try Data("x".utf8).write(to: dir.appendingPathComponent("store.db-shm"))
        try await Task.sleep(for: .milliseconds(600))
        reader.cancel()
        let got = await reader.value
        #expect(!got)
    }

    @Test func aTriggerDuringAPollRunsOneMorePollAndKillsNothing() async throws {
        let (triggers, tc) = AsyncStream<Void>.makeStream()
        let gate = Gate()
        let feed = ChangeFeed(
            fetch: { since in
                let n = await gate.enter()
                if n == 2 { try await Task.sleep(for: .milliseconds(400)) }  // the poll a trigger arrives in
                try Task.checkCancellation()  // a cancel would show here as a false failure
                return since == 1 ? [change(2)] : []
            },
            triggers: triggers, debounce: .milliseconds(30), after: 1)
        var it = feed.updates().makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(150))  // start poll (call 1)
        tc.yield()
        try await Task.sleep(for: .milliseconds(150))  // debounce ended, poll 2 is running
        tc.yield()  // trigger during the poll
        #expect(await next(&it) == .changes([change(2)]))
        try await Task.sleep(for: .milliseconds(800))
        #expect(await gate.count() == 3)  // start, the poll, one more poll
        tc.finish()
        #expect(await next(&it) == .unchanged)  // the poll a trigger started
        #expect(await next(&it) == .unchanged)  // the one more poll
        #expect(await next(&it) == nil)  // no failure was published
    }

    /// SQLite makes and deletes `loam.db-wal` each time a CLI read opens and closes the store, so
    /// only the marker counts. Without that, each poll starts the next one.
    @Test func feedFollowsLoamHomeAndIgnoresEverythingButTheMarker() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("loam-home-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appendingPathComponent("plots"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("worktrees"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        #expect(DirectoryWatcher.home(environment: ["LOAM_HOME": home.path]).path == home.path)
        let log = FakeLog([1])
        let env = ["LOAM_HOME": home.path]
        let feed = ChangeFeed(
            fetch: { try await log.fetch($0) },
            makeTriggers: { DirectoryWatcher.storeEvents(environment: env) },
            debounce: .milliseconds(50), after: 1)
        try await Task.sleep(for: .milliseconds(1000))  // the folder's own events pass first
        var it = feed.updates().makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(500))  // let FSEvents start
        let before = await log.calls().count
        try Data("x".utf8).write(to: home.appendingPathComponent("plots/a.json"))
        try Data("x".utf8).write(to: home.appendingPathComponent("worktrees/b"))
        try Data("x".utf8).write(to: home.appendingPathComponent("loam.db"))
        try Data("x".utf8).write(to: home.appendingPathComponent("loam.db-wal"))
        try fm.removeItem(at: home.appendingPathComponent("loam.db-wal"))
        try await Task.sleep(for: .milliseconds(700))
        #expect(await log.calls().count == before)  // no poll for those writes
        await log.add(2)
        try Data("x".utf8).write(to: home.appendingPathComponent("loam.changed"))
        #expect(await nextChanges(&it) == .changes([change(2)]))
    }

    /// `loam mcp` keeps the database open, so its writes reach the feed through the marker that
    /// each commit rewrites (ticket 67).
    @Test func theChangedMarkerDrivesTheFeed() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("loam-home-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let log = FakeLog([1])
        let env = ["LOAM_HOME": home.path]
        let feed = ChangeFeed(
            fetch: { try await log.fetch($0) },
            makeTriggers: { DirectoryWatcher.storeEvents(environment: env) },
            debounce: .milliseconds(50), after: 1)
        try await Task.sleep(for: .milliseconds(1000))  // the folder's own events pass first
        var it = feed.updates().makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(500))  // let FSEvents start
        await log.add(2)
        try Data("1".utf8).write(to: home.appendingPathComponent("loam.changed"))
        #expect(await nextChanges(&it) == .changes([change(2)]))
    }
}

private actor Gate {
    var n = 0
    func enter() -> Int { n += 1; return n }
    func count() -> Int { n }
}
