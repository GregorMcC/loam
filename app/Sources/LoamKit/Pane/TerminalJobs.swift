import Darwin

/// Tells whether the terminal of a shell pane runs anything apart from its shell at a prompt (ticket 113). A close of
/// the pane hangs up each process on the terminal: a job in the foreground, a job in the background (`npm run dev &`),
/// and a job that ⌃Z stopped, such as an editor with edits that are not saved. So a pane is idle only when the one
/// shell is the only process on its terminal, apart from `login`, and the shell leads the foreground group.
///
/// libghostty starts the shell of a pane as a child of the app, or as a child of `/usr/bin/login`, which it puts before
/// the command on macOS. Anything else counts as busy: a command in place of the shell (`exec vim`, or a Ghostty
/// `command` that is not a shell), a helper that the shell started (a prompt daemon such as `gitstatusd`), and a
/// process that the app cannot read. That is the careful side: Loam asks.
public enum TerminalJobs {
    /// A process, as `sysctl` gives it.
    public struct Process: Equatable, Sendable {
        public var pid: pid_t
        public var parent: pid_t
        public var group: pid_t
        /// The controlling terminal, or `noTerminal`.
        public var terminal: dev_t
        /// The foreground process group of the controlling terminal, or 0.
        public var foreground: pid_t
        public var name: String

        public init(pid: pid_t, parent: pid_t, group: pid_t, terminal: dev_t, foreground: pid_t, name: String) {
            self.pid = pid
            self.parent = parent
            self.group = group
            self.terminal = terminal
            self.foreground = foreground
            self.name = name
        }
    }

    /// The device of a process with no controlling terminal (`NODEV`).
    public static let noTerminal: dev_t = -1

    /// The names of the shells that a pane can run.
    static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "mksh", "tcsh", "csh", "fish", "nu", "elvish",
                                      "xonsh", "pwsh"]

    /// True when the terminal runs anything apart from one shell at its prompt. `foreground` is the foreground process
    /// group of the terminal, and `app` is the pid of the app. `read` gives a process, and `onTerminal` gives each
    /// process whose controlling terminal is the device. Each gives nil when it cannot read.
    public static func busy(foreground: pid_t, app: pid_t, read: (pid_t) -> Process?,
                            onTerminal: (dev_t) -> [Process]?) -> Bool {
        guard foreground > 0, let shell = read(foreground), shell.group == shell.pid, shells.contains(shell.name),
              shell.terminal != noTerminal else { return true }
        var login: pid_t?
        if shell.parent != app {
            guard let parent = read(shell.parent), parent.name == "login", parent.parent == app else { return true }
            login = parent.pid
        }
        guard let processes = onTerminal(shell.terminal) else { return true }
        return processes.contains { $0.pid != shell.pid && $0.pid != login }
    }

    /// A process from `sysctl`, which also reads a process of another user, such as `login`. Nil when it is gone.
    public static func read(_ pid: pid_t) -> Process? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return process(info)
    }

    /// Each process whose controlling terminal is the device, from `sysctl`. Nil when the app cannot read them.
    public static func onTerminal(_ device: dev_t) -> [Process]? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, device]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0 else { return nil }
        // Room for processes that start between the two calls.
        var infos = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 8)
        size = infos.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, 4, &infos, &size, nil, 0) == 0 else { return nil }
        return infos.prefix(size / MemoryLayout<kinfo_proc>.stride).map(process)
    }

    private static func process(_ info: kinfo_proc) -> Process {
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return Process(pid: info.kp_proc.p_pid, parent: info.kp_eproc.e_ppid, group: info.kp_eproc.e_pgid,
                       terminal: info.kp_eproc.e_tdev, foreground: info.kp_eproc.e_tpgid, name: name)
    }
}
