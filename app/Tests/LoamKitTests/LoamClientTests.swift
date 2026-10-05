import Foundation
import Testing
@testable import LoamKit

/// A fake `loam`: a shell script that prints a fixture, records its arguments and stdin, and exits with a code.
/// Puts a fake binary at `path` without writing a new executable file. macOS scans each new
/// executable on its first launch. With every test writing its own, that scan held launches
/// for over 10 s in a full parallel run. So `path` is a link to one shared launcher, and the
/// script itself is a plain file next to it that `/bin/sh` reads.
enum FakeScript {
    static let launcher: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-loam-launcher-\(UUID().uuidString)")
        // A script run through a link gets the link path as $0.
        try! "#!/bin/sh\nexec /bin/sh \"$0.sh\" \"$@\"\n".write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }()

    static func install(_ script: String, at path: URL) throws {
        try script.write(to: path.appendingPathExtension("sh"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: launcher)
    }
}

struct FakeLoam {
    let dir: URL
    var binary: URL { dir.appendingPathComponent("loam") }
    /// The script that `binary` runs. A test can replace it.
    var script: URL { dir.appendingPathComponent("loam.sh") }
    var argsLog: URL { dir.appendingPathComponent("args.log") }
    var stdinLog: URL { dir.appendingPathComponent("stdin.log") }

    /// `outputs` holds one entry per call: the fixture name (or "" for none) and the exit code.
    /// The script keeps a call counter, so a test can script a sequence. The last entry repeats.
    init(_ outputs: [(fixture: String, exit: Int32)]) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-loam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cases = ""
        for (i, o) in outputs.enumerated() {
            let file = o.fixture.isEmpty ? "/dev/null" : Fixtures.dir.appendingPathComponent("\(o.fixture).json").path
            cases += "  \(i)) cat '\(file)'; exit \(o.exit);;\n"
        }
        let last = outputs.count - 1
        let script = """
        #!/bin/sh
        n=$(cat '\(dir.path)/count' 2>/dev/null || echo 0)
        echo $((n+1)) > '\(dir.path)/count'
        echo "$@" >> '\(argsLog.path)'
        if [ ! -t 0 ]; then cat >> '\(stdinLog.path)'; fi
        [ "$n" -gt \(last) ] && n=\(last)
        case $n in
        \(cases)esac
        """
        try FakeScript.install(script, at: binary)
    }

    func args() -> [String] {
        ((try? String(contentsOf: argsLog, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func client() -> LoamClient { LoamClient(binary: binary) }
}

@Suite struct LoamClientTests {
    @Test func readsUseJSONOnly() async throws {
        let fake = try FakeLoam([("list", 0)])
        let plots = try await fake.client().list()
        #expect(plots.map(\.name) == ["Loam", "Loam Docs"])
        #expect(fake.args() == ["list --json"])
    }

    @Test func writesUseActorApp() async throws {
        let fake = try FakeLoam([("link_add", 0)])
        let result = try await fake.client().linkAdd(plot: "Loam", label: "Spec", target: "https://example.com/spec", note: "The v1 spec")
        #expect(result.changeID == 5)
        #expect(result.link?.label == "Spec")
        #expect(fake.args() == ["link add Loam Spec https://example.com/spec --note The v1 spec --json --actor app"])
    }

    @Test func setSendsTextOnStdinWithExpectedVersions() async throws {
        let fake = try FakeLoam([("set", 0)])
        let plot = try await fake.client().set(plot: "Loam", field: .whereItStands, text: "-dash text\nline 2", expect: ["where": 4, "name": 1])
        #expect(plot.revision > 0)
        #expect(fake.args() == ["set Loam where-it-stands - --expect name=1 --expect where=4 --json --actor app"])
        #expect(try String(contentsOf: fake.stdinLog, encoding: .utf8) == "-dash text\nline 2")
    }

    @Test func changesSinceIsARead() async throws {
        let fake = try FakeLoam([("changes_since", 0)])
        let changes = try await fake.client().changes(since: 7)
        #expect(!changes.isEmpty)
        #expect(fake.args() == ["changes --since 7 --json"])
    }

    @Test func undoWithOverwrite() async throws {
        let fake = try FakeLoam([("undo_overwrite", 0)])
        _ = try await fake.client().undo(changeID: 3, overwrite: true)
        #expect(fake.args() == ["undo 3 --overwrite --json --actor app"])
    }

    @Test func staleWriteCarriesCurrentValues() async throws {
        let fake = try FakeLoam([("error_stale", 10)])
        do {
            _ = try await fake.client().set(plot: "Loam", field: .what, text: "x", expect: ["what": 1])
            Issue.record("expected a throw")
        } catch let LoamError.stale(details, _) {
            #expect(details?.plotID == "plotaaaaab")
            #expect(details?.items.first?.item == "what")
            #expect(details?.items.first?.current == 17)
        }
    }

    @Test func undoClashCarriesLaterChanges() async throws {
        let fake = try FakeLoam([("error_undo_clash", 11)])
        do {
            _ = try await fake.client().undo(changeID: 3, overwrite: false)
            Issue.record("expected a throw")
        } catch let LoamError.undoClash(details, _) {
            #expect(details?.laterChanges.map(\.id) == [4])
            #expect(details?.undoWouldWrite.first?.new == "")
        }
    }

    @Test func eachExitCodeMapsToItsError() async throws {
        let cases: [(Int32, (LoamError) -> Bool)] = [
            (1, { if case .failed = $0 { true } else { false } }),
            (2, { if case .invalid = $0 { true } else { false } }),
            (10, { if case .stale = $0 { true } else { false } }),
            (11, { if case .undoClash = $0 { true } else { false } }),
            (12, { if case .linkPathMissing(_, _) = $0 { true } else { false } }),
            (13, { if case .contractMismatch = $0 { true } else { false } }),
            (14, { if case .unknownPlot = $0 { true } else { false } }),
            (15, { if case .ambiguous = $0 { true } else { false } }),
            (99, { if case .unknown(exitCode: 99, _) = $0 { true } else { false } }),
        ]
        for (code, matches) in cases {
            // Empty stdout: the exit code alone decides the case.
            let fake = try FakeLoam([("", code)])
            do {
                _ = try await fake.client().list()
                Issue.record("exit \(code) did not throw")
            } catch let e as LoamError {
                #expect(matches(e), "exit \(code) gave \(e)")
            }
        }
    }

    @Test func exitCodeWinsOverMessageText() async throws {
        // error_invalid.json says kind "invalid"; the exit code 15 decides.
        let fake = try FakeLoam([("error_invalid", 15)])
        do {
            _ = try await fake.client().list()
            Issue.record("expected a throw")
        } catch let LoamError.ambiguous(message) {
            #expect(!message.isEmpty)
        }
    }

    @Test func missingBinary() async throws {
        let client = LoamClient(binary: URL(fileURLWithPath: "/nonexistent/loam"))
        do {
            _ = try await client.list()
            Issue.record("expected a throw")
        } catch let LoamError.binaryMissing(path) {
            #expect(path == "/nonexistent/loam")
        }
    }

    @Test func badJSONOnSuccessIsUndecodable() async throws {
        let fake = try FakeLoam([("version", 0)])
        do {
            _ = try await fake.client().list()  // version.json is an object, not an array
            Issue.record("expected a throw")
        } catch LoamError.undecodable {
        }
    }

    @Test func contractCheckPasses() async throws {
        let fake = try FakeLoam([("version", 0)])
        let info = try await fake.client().checkContract()
        #expect(info.contractVersion == LoamKit.contractVersion)
    }

    @Test func contractMismatchSaysWhichSideToUpdate() async throws {
        let fake = try FakeLoam([("version", 0)])
        let client = LoamClient(binary: fake.binary, expectedContract: 2)
        do {
            _ = try await client.checkContract()
            Issue.record("expected a throw")
        } catch let error as LoamError {
            #expect(error == .contractVersionMismatch(core: 1, app: 2))
            #expect(error.userMessage.contains("Update the loam command"))
        }
        let newer = LoamClient(binary: fake.binary, expectedContract: 0)
        do {
            _ = try await newer.checkContract()
        } catch let error as LoamError {
            #expect(error.userMessage.contains("Update the app"))
        }
    }

    @Test func setupCheckReadsTheReport() async throws {
        let fake = try FakeLoam([("setup_check", 0)])
        let check = try await fake.client().setupCheck()
        #expect(check.needsBanner)
        #expect(fake.args() == ["setup --check --json"])
    }

    @Test func loamHomeIsPassedToTheProcess() async throws {
        let fake = try FakeLoam([("version", 0)])
        // Replace the script with one that prints the env.
        let script = "#!/bin/sh\necho \"{\\\"version\\\":\\\"$LOAM_HOME\\\",\\\"contract_version\\\":1}\"\n"
        try script.write(to: fake.script, atomically: true, encoding: .utf8)
        let client = LoamClient(binary: fake.binary, environment: ["LOAM_HOME": "/tmp/h"])
        #expect(try await client.version().version == "/tmp/h")
    }
}

@Suite struct LoamClientEnvironmentTests {
    @Test func aLoamProcessDoesNotInheritTheGhosttyResourcesFolder() {
        let env = LoamClient.childEnvironment(
            inherited: ["GHOSTTY_RESOURCES_DIR": "/app/ghostty", "PATH": "/usr/bin", "LOAM_HOME": "/a"],
            extra: ["LOAM_HOME": "/b"])
        #expect(env == ["PATH": "/usr/bin", "LOAM_HOME": "/b"])
    }
}

@Suite struct LoamClientProcessTests {
    private func script(_ body: String) throws -> LoamClient {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-loam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent("loam")
        try FakeScript.install("#!/bin/sh\n\(body)\n", at: bin)
        return LoamClient(binary: bin)
    }

    /// Many calls at once must all finish. A runner that blocked dispatch threads while it waited
    /// used up the pool (64 threads) and deadlocked for good. A regression can starve the test's own
    /// timer too, so it may show as a hung run rather than a failure.
    @Test(.timeLimit(.minutes(1))) func manyCallsAtOnceAllFinish() async throws {
        let client = try script("sleep 0.2; echo '{\"version\":\"x\",\"contract_version\":1}'")
        let calls = 80
        let finished = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<calls {
                group.addTask { (try? await client.version()) != nil }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(finished == calls)
    }

    @Test func aCancelledCallThrowsCancellationError() async throws {
        let client = try script("exec sleep 30")
        let task = Task { try await client.list() }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected a throw")
        } catch is CancellationError {
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func aSignalExitDoesNotMapToAContractCode() async throws {
        let client = try script("kill -TERM $$")  // exit by SIGTERM (15 is ambiguous in the table)
        do {
            _ = try await client.list()
            Issue.record("expected a throw")
        } catch let error as LoamError {
            if case .ambiguous = error { Issue.record("signal mapped to a contract code") }
            if case .invalid = error { Issue.record("signal mapped to a contract code") }
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}
