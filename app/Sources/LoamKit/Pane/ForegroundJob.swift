import Darwin

/// Tells whether the terminal of a shell pane runs a job: a process other than the shell at its prompt (ticket 113).
/// While the shell waits at its prompt, the foreground process group of the terminal is the group of the shell. While
/// a job runs, it is the group of the job, whose leader is a child of the shell. libghostty starts the shell of a pane
/// as a child of the app, or as a child of `/usr/bin/login`, which it puts before the command on macOS.
public enum ForegroundJob {
    /// The parent and the name of a process.
    public struct Process: Equatable, Sendable {
        public var parent: pid_t
        public var name: String

        public init(parent: pid_t, name: String) {
            self.parent = parent
            self.name = name
        }
    }

    /// True when the leader of `group` is not the shell of the pane. `app` is the pid of the app, and `read` gives a
    /// process, or nil when it is gone. A group that the app cannot read counts as a job.
    public static func runs(group: pid_t, app: pid_t, read: (pid_t) -> Process?) -> Bool {
        guard group > 0, let leader = read(group) else { return true }
        if leader.parent == app { return false }
        guard let parent = read(leader.parent) else { return true }
        return !(parent.name == "login" && parent.parent == app)
    }

    /// A process from `sysctl`, which also reads a process of another user, such as `login`. Nil when it is gone.
    public static func read(_ pid: pid_t) -> Process? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return Process(parent: info.kp_eproc.e_ppid, name: command)
    }
}
