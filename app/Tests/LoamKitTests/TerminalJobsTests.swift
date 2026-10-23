import Darwin
import Foundation
import Testing
@testable import LoamKit

/// Ticket 113: a shell pane is idle only when the one shell is the only process on its terminal, apart from `login`,
/// and the shell leads the foreground group. The app is pid 1 here. libghostty starts the shell of a pane under
/// `/usr/bin/login` (pid 100), on the terminal 7.
@Suite(.timeLimit(.minutes(1))) struct TerminalJobsTests {
    typealias Process = TerminalJobs.Process

    static let login = Process(pid: 100, parent: 1, group: 100, terminal: 7, foreground: 200, name: "login")
    static let shell = Process(pid: 200, parent: 100, group: 200, terminal: 7, foreground: 200, name: "zsh")

    /// A terminal with these processes on it.
    func busy(foreground: pid_t = 200, _ processes: [Process]) -> Bool {
        TerminalJobs.busy(foreground: foreground, app: 1, read: { pid in processes.first { $0.pid == pid } },
                          onTerminal: { device in processes.filter { $0.terminal == device } })
    }

    func job(_ pid: pid_t, group: pid_t? = nil, name: String = "sleep") -> Process {
        Process(pid: pid, parent: 200, group: group ?? pid, terminal: 7, foreground: 200, name: name)
    }

    @Test func aShellAtItsPromptWithNoJobIsIdle() {
        #expect(!busy([Self.login, Self.shell]))
        let direct = Process(pid: 210, parent: 1, group: 210, terminal: 8, foreground: 210, name: "bash")
        #expect(!busy(foreground: 210, [direct]), "the shell that the app started itself")
    }

    /// A background job (`npm run dev &`) and a job that ⌃Z stopped are on the terminal while the shell waits at its
    /// prompt. A close stops them, and a stopped editor loses its edits.
    @Test func aJobOnTheTerminalIsBusy() {
        #expect(busy([Self.login, Self.shell, job(300)]))
        #expect(busy([Self.login, Self.shell, job(300), job(301, group: 300, name: "node")]))
    }

    @Test func aJobInTheForegroundIsBusy() {
        #expect(busy(foreground: 300, [Self.login, Self.shell, job(300)]))
    }

    /// After `exec vim`, or with a Ghostty `command` that is not a shell, the process of the pane is not a shell.
    @Test func aCommandInPlaceOfTheShellIsBusy() {
        var vim = Self.shell
        vim.name = "vim"
        #expect(busy([Self.login, vim]))
    }

    /// A helper that the shell started, such as a prompt daemon, counts too. That is the careful side.
    @Test func aHelperOfTheShellIsBusy() {
        #expect(busy([Self.login, Self.shell, job(400, group: 200, name: "gitstatusd")]))
    }

    @Test func aLoginThatTheAppDidNotStartIsBusy() {
        var login = Self.login
        login.parent = 50
        #expect(busy([login, Self.shell]))
    }

    /// What the app cannot read counts as busy, so Loam closes nothing it is not sure about.
    @Test func whatCannotBeReadIsBusy() {
        #expect(busy(foreground: 0, [Self.login, Self.shell]))
        #expect(busy(foreground: 900, [Self.login, Self.shell]), "the leader of the group is gone")
        #expect(busy([Self.shell]), "the parent of the shell is gone")
        var notLeader = Self.shell
        notLeader.group = 100
        #expect(busy([Self.login, notLeader]), "the shell does not lead the foreground group")
        var noTerminal = Self.shell
        noTerminal.terminal = TerminalJobs.noTerminal
        #expect(busy([Self.login, noTerminal]))
        let known = [Self.login, Self.shell]
        #expect(TerminalJobs.busy(foreground: 200, app: 1, read: { pid in known.first { $0.pid == pid } }, onTerminal: { _ in nil }),
                "the processes of the terminal cannot be read")
    }

    // MARK: A real terminal

    /// `zsh -f -i` on a real terminal: `script` gives it a pty, as libghostty does, and stands for the app.
    final class Terminal: @unchecked Sendable {
        let script = Foundation.Process()
        let input = Pipe()

        init() throws {
            script.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            script.arguments = ["-q", "/dev/null", "/bin/zsh", "-f", "-i"]
            script.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "TERM": "dumb"]
            script.standardInput = input
            script.standardOutput = FileHandle.nullDevice
            script.standardError = FileHandle.nullDevice
            try script.run()
        }

        func type(_ text: String) { input.fileHandleForWriting.write(Data(text.utf8)) }

        /// The shell: the child of `script`, once it leads the foreground group of its terminal.
        func shell() async throws -> Process {
            var found: Process?
            try await until("the shell takes its terminal") {
                found = children().compactMap(TerminalJobs.read).first { $0.foreground == $0.pid }
                return found != nil
            }
            return try #require(found)
        }

        func children() -> [pid_t] {
            let pgrep = Foundation.Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-P", "\(script.processIdentifier)"]
            let out = Pipe()
            pgrep.standardOutput = out
            try? pgrep.run()
            pgrep.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").compactMap { pid_t($0) }
        }

        /// True when the check of a pane says busy for the terminal of the shell now.
        func busy(_ shell: Process) -> Bool {
            let foreground = TerminalJobs.read(shell.pid)?.foreground ?? 0
            return TerminalJobs.busy(foreground: foreground, app: script.processIdentifier, read: TerminalJobs.read,
                                     onTerminal: TerminalJobs.onTerminal)
        }

        func jobs(_ shell: Process) -> [Process] {
            (TerminalJobs.onTerminal(shell.terminal) ?? []).filter { $0.pid != shell.pid }
        }

        /// Waits until `condition` holds. Only the time limit of the suite ends the wait early (see `waitUntil`).
        func until(_ what: String, _ condition: () -> Bool) async throws {
            while !condition(), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            try #require(condition(), "\(what) did not happen")
        }

        /// Ends the shell and each process on its terminal.
        func end(_ shell: Process?) {
            if let shell {
                for job in jobs(shell) { kill(job.pid, SIGKILL) }
                kill(shell.pid, SIGKILL)
            }
            script.terminate()
        }
    }

    @Test func aRealShellAtItsPromptIsIdle() async throws {
        let terminal = try Terminal()
        var shell: Process?
        defer { terminal.end(shell) }
        shell = try await terminal.shell()
        let found = try #require(shell)
        #expect(found.name == "zsh" && found.terminal != TerminalJobs.noTerminal)
        #expect(!terminal.busy(found))
    }

    @Test func aRealBackgroundJobIsBusy() async throws {
        let terminal = try Terminal()
        var shell: Process?
        defer { terminal.end(shell) }
        shell = try await terminal.shell()
        let found = try #require(shell)
        terminal.type("sleep 300 &\n")
        try await terminal.until("the job starts") { terminal.jobs(found).contains { $0.name == "sleep" } }
        try await terminal.until("the shell is at its prompt") { TerminalJobs.read(found.pid)?.foreground == found.pid }
        #expect(terminal.busy(found))
    }

    @Test func aRealSuspendedJobIsBusy() async throws {
        let terminal = try Terminal()
        var shell: Process?
        defer { terminal.end(shell) }
        shell = try await terminal.shell()
        let found = try #require(shell)
        terminal.type("sleep 300\n")
        // Wait for `sleep` itself to lead the foreground group. The shell gives the terminal to the job before the job
        // runs `sleep`, and a ⌃Z in that gap is lost: the job still ignores it, as the shell does.
        try await terminal.until("sleep takes the foreground") {
            let foreground = TerminalJobs.read(found.pid)?.foreground
            return terminal.jobs(found).contains { $0.name == "sleep" && $0.pid == foreground }
        }
        #expect(terminal.busy(found))
        terminal.type("\u{1A}")  // ⌃Z
        try await terminal.until("the shell takes the foreground again") { TerminalJobs.read(found.pid)?.foreground == found.pid }
        #expect(terminal.jobs(found).contains { $0.name == "sleep" }, "the stopped job is gone")
        #expect(terminal.busy(found))
    }

    @Test func aRealExecInPlaceOfTheShellIsBusy() async throws {
        let terminal = try Terminal()
        var shell: Process?
        defer { terminal.end(shell) }
        shell = try await terminal.shell()
        let found = try #require(shell)
        terminal.type("exec sleep 300\n")
        try await terminal.until("the shell becomes sleep") { TerminalJobs.read(found.pid)?.name == "sleep" }
        #expect(terminal.busy(found))
    }
}
