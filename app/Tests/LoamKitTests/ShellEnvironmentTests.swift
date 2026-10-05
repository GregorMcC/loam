import Foundation
import Testing
@testable import LoamKit

@Suite struct ShellEnvironmentTests {
    /// A fake login shell. It ignores its arguments and runs `body`.
    private func shell(_ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("sh")
        try FakeScript.install("#!/bin/sh\n\(body)\n", at: path)
        return path.path
    }

    private let start = ShellEnvironment.startMarker
    private let end = ShellEnvironment.endMarker

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

    @Test(.timeLimit(.minutes(1))) func readsThePathFromTheShellDespiteNoise() async throws {
        let sh = try shell("echo 'zshrc banner'; echo oops >&2; printf '%s' '\(start)/x/bin:/y/bin\(end)'; echo more")
        #expect(await ShellEnvironment.resolvedPath(shell: sh, timeout: 5) == "/x/bin:/y/bin")
    }

    @Test(.timeLimit(.minutes(1))) func theShellRunsLoginAndInteractiveWithNoInput() async throws {
        let sh = try shell("""
        [ "$1 $2 $3" = "-l -i -c" ] || exit 3
        read -r line && exit 4
        printf '%s' '\(start)/ok\(end)'
        """)
        #expect(await ShellEnvironment.resolvedPath(shell: sh, timeout: 5) == "/ok")
    }

    @Test(.timeLimit(.minutes(1))) func aShellThatFailsGivesNoPath() async throws {
        let sh = try shell("echo broken >&2; exit 1")
        #expect(await ShellEnvironment.resolvedPath(shell: sh, timeout: 5) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aMissingShellGivesNoPath() async {
        #expect(await ShellEnvironment.resolvedPath(shell: "/no/such/shell", timeout: 5) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aShellThatHangsIsStoppedAtTheTimeLimit() async throws {
        // The trap makes the shell ignore terminate, so the kill path runs too.
        let sh = try shell("trap '' TERM; while :; do sleep 1; done")
        let began = Date()
        #expect(await ShellEnvironment.resolvedPath(shell: sh, timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(began) < 5)
    }

    @Test(.timeLimit(.minutes(1))) func applySetsTheResolvedPathBeforeTheCurrentOnes() async throws {
        let sh = try shell("printf '%s' '\(start)/home/.local/bin\(end)'")
        var set: String?
        await ShellEnvironment.apply(shell: sh, timeout: 5, currentPath: "/usr/bin:/bin") { set = $0 }
        #expect(set == "/home/.local/bin:/usr/bin:/bin")
    }

    @Test(.timeLimit(.minutes(1))) func applyKeepsThePathWhenTheShellFails() async throws {
        let sh = try shell("exit 1")
        var set: String?
        await ShellEnvironment.apply(shell: sh, timeout: 5, currentPath: "/usr/bin:/bin") { set = $0 }
        #expect(set == nil)
    }

    @Test func aPaneAndALoamCallCarryThePathThatApplySet() {
        // Panes and `loam` calls both start from the app's process environment, where apply sets PATH.
        let inherited = ["PATH": "/home/.local/bin:/usr/bin", "CLAUDECODE": "1"]
        #expect(PaneEnvironment.scrubbed(inherited)["PATH"] == "/home/.local/bin:/usr/bin")
        #expect(LoamClient.childEnvironment(inherited: inherited, extra: [:])["PATH"] == "/home/.local/bin:/usr/bin")
    }
}
