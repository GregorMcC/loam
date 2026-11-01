import Foundation
import Testing
@testable import LoamKit

@Suite(.temporaryFolders) struct ShellEnvironmentTests {
    /// A fake login shell. It ignores its arguments and runs `body`.
    private func shell(_ body: String) throws -> String {
        let dir = temporaryFolder("fake-shell")
        let path = dir.appendingPathComponent("sh")
        try FakeScript.install("#!/bin/sh\n\(body)\n", at: path)
        return path.path
    }

    private let start = ShellEnvironment.startMarker
    private let end = ShellEnvironment.endMarker
    /// The timeout of a shell in the tests that do not test the timeout. A busy machine can make a shell take more than
    /// the 5 s of the app, so these tests give it more time than a run can take. Their time limit (`.waitLimit`) is
    /// longer than this, so a shell that hangs fails at the check of the answer. Only
    /// `aShellThatHangsIsStoppedAtTheTimeLimit` tests the timeout.
    private let slow: TimeInterval = 240

    @Test func parsesThePathBetweenTheMarkers() {
        let output = "banner\nerror: nope\n\(start)/a/bin:/b/bin\(end)\ntrailing\n"
        #expect(ShellEnvironment.parsePath(output) == "/a/bin:/b/bin")
    }

    @Test func parsingFindsNoPathWithoutBothMarkersOrWithNothingBetween() {
        #expect(ShellEnvironment.parsePath("no markers") == nil)
        #expect(ShellEnvironment.parsePath("\(start)/a") == nil)
        #expect(ShellEnvironment.parsePath("\(start)\(end)") == nil)
    }

    @Test func mergeKeepsTheResolvedEntriesFirstThenTheNewOnes() {
        let merged = ShellEnvironment.merge(resolved: "/home/.local/bin:/usr/bin", current: "/usr/bin:/bin:/home/.local/bin:/sbin")
        #expect(merged == "/home/.local/bin:/usr/bin:/bin:/sbin")
    }

    @Test func mergeDropsEmptyEntriesAndDuplicates() {
        #expect(ShellEnvironment.merge(resolved: "/a::/a:/b", current: ":/b:/c") == "/a:/b:/c")
    }

    @Test(.waitLimit) func readsThePathFromTheShellDespiteNoise() async throws {
        let sh = try shell("echo 'zshrc banner'; echo oops >&2; printf '%s' '\(start)/x/bin:/y/bin\(end)'; echo more")
        #expect(await ShellEnvironment.resolvedPath(shell: sh, timeout: slow) == "/x/bin:/y/bin")
    }

    @Test(.waitLimit) func theShellRunsLoginAndInteractiveWithNoInput() async throws {
        let sh = try shell("""
        [ "$1 $2 $3" = "-l -i -c" ] || exit 3
        read -r line && exit 4
        printf '%s' '\(start)/ok\(end)'
        """)
        #expect(await ShellEnvironment.resolvedPath(shell: sh, timeout: slow) == "/ok")
    }

    @Test(.waitLimit) func aShellThatFailsGivesNoPath() async throws {
        let sh = try shell("echo broken >&2; exit 1")
        #expect(await ShellEnvironment.resolvedPath(shell: sh, timeout: slow) == nil)
    }

    @Test(.waitLimit) func aMissingShellGivesNoPath() async {
        #expect(await ShellEnvironment.resolvedPath(shell: "/no/such/shell", timeout: slow) == nil)
    }

    @Test(.waitLimit) func aShellThatHangsIsStoppedAtTheTimeLimit() async throws {
        // The trap makes the shell ignore terminate, so the kill path runs too.
        let sh = try shell("trap '' TERM; while :; do sleep 1; done")
        let began = Date()
        #expect(await ShellEnvironment.resolvedPath(shell: sh, timeout: 0.5) == nil)
        // The shell never ends, so only the timeout can end the call. The bound is loose, because a busy machine can
        // hold the launch of the shell for many seconds.
        #expect(Date().timeIntervalSince(began) < 60)
    }

    @Test(.waitLimit) func applySetsTheResolvedPathBeforeTheCurrentOnes() async throws {
        let sh = try shell("printf '%s' '\(start)/home/.local/bin\(end)'")
        var set: String?
        await ShellEnvironment.apply(shell: sh, timeout: slow, currentPath: "/usr/bin:/bin") { set = $0 }
        #expect(set == "/home/.local/bin:/usr/bin:/bin")
    }

    @Test(.waitLimit) func applyKeepsThePathWhenTheShellFails() async throws {
        let sh = try shell("exit 1")
        var set: String?
        await ShellEnvironment.apply(shell: sh, timeout: slow, currentPath: "/usr/bin:/bin") { set = $0 }
        #expect(set == nil)
    }

    @Test func aPaneAndALoamCallCarryThePathThatApplySet() {
        // Panes and `loam` calls both start from the app's process environment, where apply sets PATH.
        let inherited = ["PATH": "/home/.local/bin:/usr/bin", "CLAUDECODE": "1"]
        #expect(PaneEnvironment.scrubbed(inherited)["PATH"] == "/home/.local/bin:/usr/bin")
        #expect(LoamClient.childEnvironment(inherited: inherited, extra: [:])["PATH"] == "/home/.local/bin:/usr/bin")
    }
}
