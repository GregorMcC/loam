import Darwin
import Testing
@testable import LoamKit

@Suite struct SafeCloseTests {
    @Test func hangsUpTheForegroundGroupFirst() {
        var close = SafeClose(startedAt: 0)

        #expect(close.next(now: 0, foreground: 500, exited: false) == [.signal(group: 500, SIGHUP)])
    }

    @Test func freesOnlyAfterTheProcessExits() {
        var close = SafeClose(startedAt: 0)
        _ = close.next(now: 0, foreground: 500, exited: false)

        #expect(close.next(now: 0.01, foreground: 500, exited: false) == [])
        #expect(close.next(now: 0.02, foreground: nil, exited: true) == [.free])
        #expect(close.isFinished)
    }

    @Test func freesAtOnceWhenTheProcessHasAlreadyExited() {
        var close = SafeClose(startedAt: 0)

        #expect(close.next(now: 0, foreground: nil, exited: true) == [.free])
    }

    @Test func hangsUpTheShellWhenItsForegroundJobDies() {
        // A shell runs `yes` in the foreground. SIGHUP ends `yes`, and the
        // shell takes the terminal back. The shell must get its own SIGHUP.
        var close = SafeClose(startedAt: 0)
        _ = close.next(now: 0, foreground: 600, exited: false)

        #expect(close.next(now: 0.01, foreground: 500, exited: false) == [.signal(group: 500, SIGHUP)])
        #expect(close.next(now: 0.02, foreground: 500, exited: false) == [])
    }

    @Test func killsEveryGroupItHungUpAfterTwoSeconds() {
        var close = SafeClose(startedAt: 0)
        _ = close.next(now: 0, foreground: 600, exited: false)
        _ = close.next(now: 0.5, foreground: 500, exited: false)

        #expect(close.next(now: 1.99, foreground: 500, exited: false) == [])
        #expect(close.next(now: 2.0, foreground: 500, exited: false) == [
            .signal(group: 500, SIGKILL), .signal(group: 600, SIGKILL),
        ])
        #expect(close.next(now: 2.1, foreground: 500, exited: false) == [])
    }

    @Test func killsANewForegroundGroupAfterTheDeadline() {
        var close = SafeClose(startedAt: 0)
        _ = close.next(now: 0, foreground: 600, exited: false)
        _ = close.next(now: 2.0, foreground: 600, exited: false)

        #expect(close.next(now: 2.1, foreground: 700, exited: false) == [.signal(group: 700, SIGKILL)])
    }

    @Test func freesAnywayWhenTheProcessNeverExits() {
        var close = SafeClose(startedAt: 0)
        _ = close.next(now: 0, foreground: 600, exited: false)
        _ = close.next(now: 2.0, foreground: 600, exited: false)

        #expect(close.next(now: 4.99, foreground: 600, exited: false) == [])
        #expect(close.next(now: 5.0, foreground: 600, exited: false) == [.free])
        #expect(close.forced)
    }

    /// libghostty runs each command under `/usr/bin/login`. `login` exits at once on SIGHUP, but
    /// `claude` in the same group can still end its session (ticket 61).
    @Test func waitsForTheHungUpGroupAfterTheProcessExits() {
        var close = SafeClose(startedAt: 0)
        var alive: Set<pid_t> = [500]
        _ = close.next(now: 0, foreground: 500, exited: false, groupAlive: alive.contains)

        #expect(close.next(now: 0.01, foreground: 500, exited: true, groupAlive: alive.contains) == [])
        #expect(!close.isFinished)
        alive = []
        #expect(close.next(now: 1.5, foreground: nil, exited: true, groupAlive: alive.contains) == [.free])
        #expect(!close.forced)
    }

    @Test func killsAHungUpGroupThatOutlivesTheProcess() {
        var close = SafeClose(startedAt: 0)
        let alive: Set<pid_t> = [500]
        _ = close.next(now: 0, foreground: 500, exited: false, groupAlive: alive.contains)

        #expect(close.next(now: 1.0, foreground: nil, exited: true, groupAlive: alive.contains) == [])
        #expect(close.next(now: 2.0, foreground: nil, exited: true, groupAlive: alive.contains) == [.signal(group: 500, SIGKILL)])
        #expect(close.next(now: 5.0, foreground: nil, exited: true, groupAlive: alive.contains) == [.free])
        #expect(close.forced)
    }

    @Test func doesNothingAfterTheFree() {
        var close = SafeClose(startedAt: 0)
        _ = close.next(now: 0, foreground: nil, exited: true)

        #expect(close.next(now: 0.1, foreground: nil, exited: true) == [])
    }
}
