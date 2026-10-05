import Foundation
import Testing
@testable import LoamKit

/// A temp folder with a settings file path in it. The file does not exist yet.
private func tempFile() throws -> SettingsFile {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loam-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return SettingsFile(url: dir.appendingPathComponent("settings.json"))
}

private func object(_ file: SettingsFile) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any] ?? [:]
}

@Suite struct SettingsFileTests {
    @Test func aMissingFileGivesTheDefaultsAndNoError() throws {
        let file = try tempFile()
        let load = file.read()
        #expect(load.settings == .defaults)
        #expect(load.settings.repoFolders == ["~/Development"])
        #expect(load.settings.loamPath == nil)
        #expect(load.error == nil)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func aMissingKeyGivesItsDefault() throws {
        let file = try tempFile()
        try #"{"loam_path": "/opt/loam"}"#.write(to: file.url, atomically: true, encoding: .utf8)
        let load = file.read()
        #expect(load.settings.repoFolders == ["~/Development"])
        #expect(load.settings.loamPath == "/opt/loam")
    }

    @Test func nullAndEmptyLoamPathMeanAutomatic() throws {
        let file = try tempFile()
        try #"{"loam_path": null}"#.write(to: file.url, atomically: true, encoding: .utf8)
        #expect(file.read().settings.loamPath == nil)
        try #"{"loam_path": "  "}"#.write(to: file.url, atomically: true, encoding: .utf8)
        #expect(file.read().settings.loamPath == nil)
    }

    @Test func anEmptyRepoFolderListStaysEmpty() throws {
        let file = try tempFile()
        try #"{"repo_folders": []}"#.write(to: file.url, atomically: true, encoding: .utf8)
        #expect(file.read().settings.repoFolders == [])
    }

    @Test func invalidJSONGivesTheDefaultsAndAnError() throws {
        let file = try tempFile()
        try "{ not json".write(to: file.url, atomically: true, encoding: .utf8)
        let load = file.read()
        #expect(load.settings == .defaults)
        #expect(load.error != nil)
    }

    @Test func aWriteThenAReadGivesTheSameSettings() throws {
        let file = try tempFile()
        let settings = LoamSettings(repoFolders: ["~/Code", "/Volumes/Work"], loamPath: "~/bin/loam")
        try file.write(settings)
        #expect(file.read() == SettingsFile.Load(settings: settings, error: nil))
        let raw = try object(file)
        #expect(raw["repo_folders"] as? [String] == ["~/Code", "/Volumes/Work"])
        #expect(raw["loam_path"] as? String == "~/bin/loam")
    }

    @Test func automaticIsWrittenAsNull() throws {
        let file = try tempFile()
        try file.write(.defaults)
        #expect(try object(file)["loam_path"] is NSNull)
    }

    @Test func aWriteKeepsKeysThatTheAppDoesNotKnow() throws {
        let file = try tempFile()
        try #"{"worktree_folder": "~/wt", "repo_folders": ["~/Old"]}"#.write(to: file.url, atomically: true, encoding: .utf8)
        try file.write(LoamSettings(repoFolders: ["~/New"], loamPath: nil))
        let raw = try object(file)
        #expect(raw["worktree_folder"] as? String == "~/wt")
        #expect(raw["repo_folders"] as? [String] == ["~/New"])
    }

    @Test func aWriteNeverReplacesInvalidJSON() throws {
        let file = try tempFile()
        try "{ not json".write(to: file.url, atomically: true, encoding: .utf8)
        #expect(throws: SettingsFile.WriteError.invalidFile) { try file.write(.defaults) }
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "{ not json")
    }

    @Test func aWriteMakesTheFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loam-settings-\(UUID().uuidString)")
        let file = SettingsFile(url: dir.appendingPathComponent("settings.json"))
        try file.write(.defaults)
        #expect(file.read().error == nil)
    }

    @Test func theFileIsInTheLoamHome() {
        let file = SettingsFile(environment: ["LOAM_HOME": "/tmp/loam-home"])
        #expect(file.url.path == "/tmp/loam-home/settings.json")
    }
}

@Suite struct SettingsPathTests {
    @Test func expandsATildeAtTheStart() {
        #expect(SettingsPath.expand("~", home: "/Users/me") == "/Users/me")
        #expect(SettingsPath.expand("~/Development", home: "/Users/me") == "/Users/me/Development")
        #expect(SettingsPath.expand("/opt/x", home: "/Users/me") == "/opt/x")
        #expect(SettingsPath.expand("~other/x", home: "/Users/me") == "~other/x")
    }

    @Test func abbreviatesAPathInTheHome() {
        #expect(SettingsPath.abbreviate("/Users/me/Development", home: "/Users/me") == "~/Development")
        #expect(SettingsPath.abbreviate("/Users/me", home: "/Users/me") == "~")
        #expect(SettingsPath.abbreviate("/Users/meta/x", home: "/Users/me") == "/Users/meta/x")
        #expect(SettingsPath.abbreviate("/opt/x", home: "/Users/me") == "/opt/x")
    }

    @Test func theRepoFoldersExpand() {
        let settings = LoamSettings(repoFolders: ["~/Code", "/srv"], loamPath: nil)
        #expect(settings.expandedRepoFolders(home: "/Users/me") == ["/Users/me/Code", "/srv"])
    }
}

@Suite struct LoamBinaryTests {
    let home = "/Users/me"

    func resolve(_ setting: String?, path: String = "", executable: Set<String>) -> LoamBinary.Resolution {
        LoamBinary.resolve(setting: setting, home: home, pathVariable: path) { executable.contains($0) }
    }

    @Test func automaticTriesTheInstallFoldersInOrder() {
        let all: Set = ["/Users/me/.local/bin/loam", "/opt/homebrew/bin/loam", "/usr/local/bin/loam"]
        #expect(resolve(nil, executable: all) == .init(path: "/Users/me/.local/bin/loam", automatic: true, found: true))
        #expect(resolve(nil, executable: all.subtracting(["/Users/me/.local/bin/loam"])).path == "/opt/homebrew/bin/loam")
        #expect(resolve(nil, executable: ["/usr/local/bin/loam"]).path == "/usr/local/bin/loam")
    }

    @Test func automaticThenTriesThePath() {
        let found = resolve(nil, path: "/a:/Users/me/go/bin:/b", executable: ["/Users/me/go/bin/loam", "/b/loam"])
        #expect(found == .init(path: "/Users/me/go/bin/loam", automatic: true, found: true))
    }

    @Test func automaticThenTriesTheCLIInTheAppBundle() {
        let bundled = "/Applications/Loam.app/Contents/Helpers/loam"
        func resolve(_ executable: Set<String>, path: String = "") -> LoamBinary.Resolution {
            LoamBinary.resolve(setting: nil, home: home, pathVariable: path, bundled: bundled) { executable.contains($0) }
        }
        #expect(resolve([bundled, "/a/loam"], path: "/a") == .init(path: bundled, automatic: true, found: true))
        #expect(resolve([bundled, "/usr/local/bin/loam"]).path == "/usr/local/bin/loam")
        // A custom path wins over the bundled CLI.
        #expect(LoamBinary.resolve(setting: "/x/loam", home: home, pathVariable: "", bundled: bundled) { _ in true }.path == "/x/loam")
    }

    @Test func automaticWithNothingFoundNamesTheDefaultInstall() {
        #expect(resolve(nil, path: "/a", executable: []) == .init(path: "/Users/me/.local/bin/loam", automatic: true, found: false))
    }

    @Test func aCustomPathWinsAndExpands() {
        let all: Set = ["/Users/me/.local/bin/loam", "/Users/me/bin/loam"]
        #expect(resolve("~/bin/loam", executable: all) == .init(path: "/Users/me/bin/loam", automatic: false, found: true))
    }

    @Test func aCustomPathThatIsMissingIsNotFound() {
        #expect(resolve("/nope/loam", executable: ["/Users/me/.local/bin/loam"]) == .init(path: "/nope/loam", automatic: false, found: false))
    }
}

@MainActor
@Suite struct SettingsModelTests {
    let home = "/Users/me"

    func model(_ file: SettingsFile, launch: String = "/Users/me/.local/bin/loam",
               check: @escaping @Sendable (String) async -> SettingsModel.LoamStatus = { _ in .ok(version: "1.0", contract: 1) }) -> SettingsModel {
        SettingsModel(file: file, launchBinary: launch, home: home,
                      resolve: { LoamBinary.resolve(setting: $0, home: "/Users/me", pathVariable: "") { _ in true } },
                      check: check)
    }

    @Test func readsTheFileAtStart() throws {
        let file = try tempFile()
        try file.write(LoamSettings(repoFolders: ["~/Code"], loamPath: nil))
        let settings = model(file)
        #expect(settings.settings.repoFolders == ["~/Code"])
        #expect(settings.repoFolderPaths == ["/Users/me/Code"])
    }

    @Test func anAddedFolderInTheHomeKeepsATilde() throws {
        let file = try tempFile()
        let settings = model(file)
        settings.addRepoFolder("/Users/me/Code")
        settings.addRepoFolder("/Users/me/Code")
        settings.addRepoFolder("/Volumes/Work")
        #expect(settings.settings.repoFolders == ["~/Development", "~/Code", "/Volumes/Work"])
        #expect(file.read().settings.repoFolders == ["~/Development", "~/Code", "/Volumes/Work"])
    }

    @Test func aRemovedFolderIsWritten() throws {
        let file = try tempFile()
        let settings = model(file)
        settings.removeRepoFolders(["~/Development"])
        #expect(file.read().settings.repoFolders == [])
    }

    @Test func eachChangeCallsOnChange() throws {
        let file = try tempFile()
        let settings = model(file)
        var seen: [[String]] = []
        settings.onChange = { seen.append($0.repoFolders) }
        settings.addRepoFolder("/srv")
        try file.write(LoamSettings(repoFolders: ["~/Hand"], loamPath: nil))
        settings.reload()
        #expect(seen == [["~/Development", "/srv"], ["~/Hand"]])
    }

    @Test func aReloadWithNoChangeCallsNothing() throws {
        let file = try tempFile()
        let settings = model(file)
        var calls = 0
        settings.onChange = { _ in calls += 1 }
        settings.reload()
        #expect(calls == 0)
    }

    @Test func anInvalidFileBlocksEditsAndShowsTheError() throws {
        let file = try tempFile()
        try "{ nope".write(to: file.url, atomically: true, encoding: .utf8)
        let settings = model(file)
        #expect(settings.fileError != nil)
        settings.addRepoFolder("/srv")
        #expect(settings.settings == .defaults)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "{ nope")
        // A fixed file clears the error.
        try "{}".write(to: file.url, atomically: true, encoding: .utf8)
        settings.reload()
        #expect(settings.fileError == nil)
    }

    @Test func aFileThatBreaksKeepsTheLastGoodSettings() throws {
        let file = try tempFile()
        try file.write(LoamSettings(repoFolders: ["~/Code"], loamPath: "~/bin/loam"))
        let settings = model(file)
        var calls = 0
        settings.onChange = { _ in calls += 1 }
        try #"{"repo_folders": ["~/Co"#.write(to: file.url, atomically: true, encoding: .utf8)
        settings.reload()
        #expect(settings.fileError != nil)
        #expect(settings.settings == LoamSettings(repoFolders: ["~/Code"], loamPath: "~/bin/loam"))
        #expect(calls == 0)
    }

    @Test func aNewLoamPathNeedsARestart() throws {
        let file = try tempFile()
        let settings = model(file)
        #expect(settings.loam.automatic)
        #expect(!settings.needsRestart)
        settings.setLoamPath("~/bin/loam")
        #expect(settings.loam.path == "/Users/me/bin/loam")
        #expect(file.read().settings.loamPath == "~/bin/loam")
        #expect(settings.needsRestart)
        settings.setLoamPath(nil)
        #expect(!settings.needsRestart)
        #expect(file.read().settings.loamPath == nil)
    }

    @Test func theCheckRunsOnTheResolvedPath() async throws {
        let file = try tempFile()
        let settings = model(file) { path in path == "/Users/me/bin/loam" ? .ok(version: "2.0", contract: 1) : .failed("no") }
        await settings.checkLoam()
        #expect(settings.loamStatus == .failed("no"))
        settings.setLoamPath("~/bin/loam")
        await settings.checkLoam()
        #expect(settings.loamStatus == .ok(version: "2.0", contract: 1))
    }
}
