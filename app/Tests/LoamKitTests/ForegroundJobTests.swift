import Darwin
import Foundation
import Testing
@testable import LoamKit

/// Ticket 113: a shell pane runs a job when the foreground process group of its terminal is not the shell. The app is
/// pid 1 here. libghostty starts the shell of a pane under `/usr/bin/login` (pid 100), or as a child of the app.
@Suite struct ForegroundJobTests {
    let table: [pid_t: ForegroundJob.Process] = [
        100: .init(parent: 1, name: "login"),
        200: .init(parent: 100, name: "zsh"),
        210: .init(parent: 1, name: "zsh"),
        300: .init(parent: 200, name: "sleep"),
        400: .init(parent: 300, name: "login"),
        500: .init(parent: 400, name: "zsh"),
    ]

    func runs(_ group: pid_t) -> Bool { ForegroundJob.runs(group: group, app: 1) { table[$0] } }

    @Test func aShellAtItsPromptRunsNoJob() {
        #expect(!runs(200), "the shell under login")
        #expect(!runs(210), "the shell that the app started itself")
        #expect(!runs(100), "login, the leader of the group of a command that it started")
    }

    @Test func aJobOfTheShellRuns() {
        #expect(runs(300))
    }

    /// A shell that a job started under its own `login` is a job of the pane's shell.
    @Test func aLoginThatTheAppDidNotStartIsAJob() {
        #expect(runs(500))
    }

    /// A group that the app cannot read counts as a job, so Loam closes nothing it is not sure about.
    @Test func aGroupThatCannotBeReadRuns() {
        #expect(runs(0))
        #expect(runs(-1))
        #expect(runs(900), "the leader of the group is gone")
        #expect(ForegroundJob.runs(group: 200, app: 1) { $0 == 200 ? table[200] : nil }, "the parent of the leader is gone")
    }

    @Test func readGivesTheParentAndTheNameOfAProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        let read = try #require(ForegroundJob.read(child.processIdentifier))
        #expect(read == ForegroundJob.Process(parent: getpid(), name: "sleep"))
        #expect(ForegroundJob.read(getpid())?.parent == getppid())
    }
}
