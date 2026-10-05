import Foundation
import Testing
@testable import LoamKit

/// Reads `contract/fixtures/` by a path relative to this file. No Go needed.
enum Fixtures {
    struct Entry: Decodable {
        var name: String
        var args: [String]
        var exitCode: Int32
        var schema: String
        enum CodingKeys: String, CodingKey { case name, args, exitCode = "exit_code", schema }
    }

    static let dir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // LoamKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // app
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("contract/fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent("\(name).json"))
    }

    static func manifest() throws -> [Entry] {
        try JSONDecoder().decode([Entry].self, from: data("manifest"))
    }
}

/// Decodes a fixture by its schema name. Every schema in the manifest needs a case here.
func decodeFixture(schema: String, data: Data) throws {
    let d = JSONDecoder()
    switch schema {
    case "version": _ = try d.decode(VersionInfo.self, from: data)
    case "list": _ = try d.decode([PlotSummary].self, from: data)
    case "show", "new", "set", "edit": _ = try d.decode(Plot.self, from: data)
    case "link-add", "link-edit", "link-rm", "repo-add", "repo-edit", "repo-main", "repo-rm":
        _ = try d.decode(WriteResult.self, from: data)
    case "sessions": _ = try d.decode([SessionRecord].self, from: data)
    case "move": _ = try d.decode(MoveResult.self, from: data)
    case "open": _ = try d.decode(OpenResult.self, from: data)
    case "pane-event": _ = try d.decode(PaneEvent.self, from: data)
    case "export": _ = try d.decode(ExportResponse.self, from: data)
    case "setup-check": _ = try d.decode(SetupCheck.self, from: data)
    case "changes": _ = try d.decode(ChangesResponse.self, from: data)
    case "undo": _ = try d.decode(UndoResult.self, from: data)
    case "worktree-new": _ = try d.decode(WorktreeNewResult.self, from: data)
    case "worktree-list": _ = try d.decode([WorktreeStatus].self, from: data)
    case "worktree-rm": _ = try d.decode(WorktreeRmResult.self, from: data)
    case "delete": _ = try d.decode(DeleteResult.self, from: data)
    default: Issue.record("No Swift type for schema \(schema)")
    }
}

@Suite struct FixtureTests {
    @Test func everyFixtureDecodes() throws {
        let entries = try Fixtures.manifest()
        #expect(entries.count >= 39)
        for e in entries {
            let data = try Fixtures.data(e.name)
            if e.exitCode == 0 {
                try decodeFixture(schema: e.schema, data: data)
            } else {
                let env = try JSONDecoder().decode(ErrorEnvelope.self, from: data)
                #expect(env.error.exitCode == Int(e.exitCode), "\(e.name)")
            }
        }
    }

    @Test func noFixtureFileIsLeftOut() throws {
        let listed = Set(try Fixtures.manifest().map(\.name) + ["manifest"])
        let files = try FileManager.default.contentsOfDirectory(atPath: Fixtures.dir.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
        #expect(Set(files) == listed)
    }

    @Test func nullsAndMissingKeysDecode() throws {
        let changes = try JSONDecoder().decode(ChangesResponse.self, from: Fixtures.data("changes"))
        #expect(changes.changes[0].entries[0].old == nil)
        #expect(changes.changes[0].entries[0].new == "Loam")
        #expect(changes.changes[0].undoOf == nil)
        #expect(changes.changes[0].actor.kind == .cli)
        #expect(changes.changes[0].actor.sessionID == nil)
        let plot = try JSONDecoder().decode(Plot.self, from: Fixtures.data("show_full"))
        #expect(plot.whereItStands == "Building.")
        #expect(plot.versions["where"] == 4)
        #expect(plot.repos[0].main)
    }

    @Test func setupCheckDrivesTheBanner() throws {
        let check = try JSONDecoder().decode(SetupCheck.self, from: Fixtures.data("setup_check"))
        #expect(check.needsBanner)
        #expect(check.pendingSteps.map(\.id) == ["mcp"])
        #expect(check.pendingSteps[0].detail != nil)
    }

    @Test func linkPathMissingCarriesItsDetails() throws {
        let env = try JSONDecoder().decode(ErrorEnvelope.self, from: Fixtures.data("error_link_path_missing"))
        let error = LoamError.from(exitCode: 12, message: env.error.message, details: env.error.details?.data)
        guard case .linkPathMissing(let details, _) = error else {
            Issue.record("wrong case: \(error)")
            return
        }
        #expect(details?.plotID == "plotaaaaab")
        #expect(details?.linkID == "linkaaaaai")
        #expect(details?.path == "/tmp/loam-contract/vault/missing.md")
    }

    @Test func newFieldsDecode() throws {
        let open = try JSONDecoder().decode(OpenResult.self, from: Fixtures.data("open_vault"))
        #expect(open.kind == .vault)
        #expect(open.openedWith == .obsidian)
        let plot = try JSONDecoder().decode(Plot.self, from: Fixtures.data("show_links"))
        #expect(plot.links.contains { $0.exists != nil })
        let wt = try JSONDecoder().decode([WorktreeStatus].self, from: Fixtures.data("worktree_list"))
        #expect(wt[0].mergedInto == "origin/main")
        let rm = try JSONDecoder().decode(WorktreeRmResult.self, from: Fixtures.data("worktree_rm"))
        #expect(rm.branchNote == nil)
        let del = try JSONDecoder().decode(DeleteResult.self, from: Fixtures.data("delete"))
        #expect(del.claudeFiles.count == 1)
    }
}
