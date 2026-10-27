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
/// libghostty can lose its report of the exit (ticket 135). Its reader and
/// its exit watcher both push to the app mailbox. When the mailbox is full,
/// the exit watcher waits once for room, and gives up if the reader fills
/// the room first. A pane that floods its title does that. So the close
/// also counts the process as exited when no process is left on the terminal
/// and libghostty has sent no action for the pane for `quietFor` seconds.
/// In that time libghostty sends the actions that it read before the exit,
/// so the free does not wait on the mailbox.
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
    public let quietFor: TimeInterval

    /// True once the caller must free the surface, or has.
    public private(set) var isFinished = false
    /// True when the free came from the give-up deadline, not a process exit.
    public private(set) var forced = false
    /// True when libghostty did not report the exit, and the close saw it on the terminal.
    public private(set) var exitReportLost = false

    private var hungUp: [pid_t] = []
    private var killed: Set<pid_t> = []
    private var escalated = false
    /// When the close first saw no process on the terminal, with no report from libghostty.
    private var emptySince: TimeInterval?

    public init(startedAt: TimeInterval, killAfter: TimeInterval = 2, giveUpAfter: TimeInterval = 5,
                quietFor: TimeInterval = 0.5) {
        self.startedAt = startedAt
        self.killAfter = killAfter
        self.giveUpAfter = giveUpAfter
        self.quietFor = quietFor
    }

    /// The steps to run now. `foreground` is the terminal's foreground process
    /// group, or nil when there is none. `exited` is libghostty's report of the
    /// exit. `groupAlive` tells if a process group still has a process.
    /// `terminalEmpty` tells if no process is left on the pane's terminal, and
    /// `lastAction` is the time of the last action from libghostty for the pane.
    public mutating func next(now: TimeInterval, foreground: pid_t?, exited: Bool,
                              groupAlive: (pid_t) -> Bool = { _ in false },
                              terminalEmpty: () -> Bool = { false }, lastAction: TimeInterval = 0) -> [Step] {
        guard !isFinished else { return [] }
        let groupsGone = !hungUp.contains(where: groupAlive)
        if groupsGone, exited {
            isFinished = true
            return [.free]
        }
        if groupsGone, terminalEmpty() {
            let since = emptySince ?? now
            emptySince = since
            if now - max(since, lastAction) >= quietFor {
                isFinished = true
                exitReportLost = true
                return [.free]
            }
        } else {
            emptySince = nil
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
