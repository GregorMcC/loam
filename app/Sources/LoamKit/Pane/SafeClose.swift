import Darwin
import Foundation

/// The safe close order for a pane (spec 8.2). It avoids the deadlock in
/// ghostty-org/ghostty#14245, where `ghostty_surface_free` waits on a reader
/// thread that waits on the app mailbox that only the main thread drains.
///
/// 1. SIGHUP to the foreground process group of the pane's terminal.
/// 2. Keep the main run loop running (so libghostty ticks) until the pane's
///    process exits. When the foreground group changes (a shell takes the
///    terminal back from its job), SIGHUP the new group too.
/// 3. After `killAfter` seconds, SIGKILL every group that got a SIGHUP.
/// 4. Free the surface once the process exits and every group that got a
///    SIGHUP is gone, or after `giveUpAfter`. libghostty runs each command
///    under `/usr/bin/login`, and `login` exits at once on SIGHUP. Its child
///    (`claude`) is in the same group and can still run (ticket 61).
///
/// The caller polls `next` on the main run loop and runs the steps it returns.
public struct SafeClose: Sendable {
    public enum Step: Equatable, Sendable {
        case signal(group: pid_t, Int32)
        case free
    }

    public let startedAt: TimeInterval
    public let killAfter: TimeInterval
    public let giveUpAfter: TimeInterval

    /// True once the caller must free the surface, or has.
    public private(set) var isFinished = false
    /// True when the free came from the give-up deadline, not a process exit.
    public private(set) var forced = false

    private var hungUp: [pid_t] = []
    private var killed: Set<pid_t> = []
    private var escalated = false

    public init(startedAt: TimeInterval, killAfter: TimeInterval = 2, giveUpAfter: TimeInterval = 5) {
        self.startedAt = startedAt
        self.killAfter = killAfter
        self.giveUpAfter = giveUpAfter
    }

    /// The steps to run now. `foreground` is the terminal's foreground process
    /// group, or nil when there is none. `groupAlive` tells if a process group
    /// still has a process.
    public mutating func next(now: TimeInterval, foreground: pid_t?, exited: Bool,
                              groupAlive: (pid_t) -> Bool = { _ in false }) -> [Step] {
        guard !isFinished else { return [] }
        if exited, !hungUp.contains(where: groupAlive) {
            isFinished = true
            return [.free]
        }
        let elapsed = now - startedAt
        if elapsed >= giveUpAfter {
            isFinished = true
            forced = true
            return [.free]
        }

        var steps: [Step] = []
        if let group = foreground, group > 0, !hungUp.contains(group) {
            hungUp.append(group)
            if !escalated { steps.append(.signal(group: group, SIGHUP)) }
        }
        if elapsed >= killAfter {
            escalated = true
            for group in hungUp.sorted() where !killed.contains(group) {
                killed.insert(group)
                steps.append(.signal(group: group, SIGKILL))
            }
        }
        return steps
    }
}
