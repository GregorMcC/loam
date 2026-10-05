import Foundation
import Testing

@testable import LoamKit

@MainActor
@Suite struct LaunchCheckTests {
    @Test func aContractMismatchBlocksAndLoadsNothing() async throws {
        let fake = try FakeLoam([("version", 0)])
        let client = LoamClient(binary: fake.binary, expectedContract: 2)
        let model = AppModel(client: client)
        await model.launch()
        #expect(model.launchBlock?.contains("older than this app") == true)
        #expect(model.launchBlock?.contains("Update the loam command") == true)
        #expect(model.plots.isEmpty)
        #expect(fake.args() == ["version --json"])
    }

    @Test func aNewerCoreTellsThePersonToUpdateTheApp() async throws {
        let fake = try FakeLoam([("version", 0)])
        let model = AppModel(client: LoamClient(binary: fake.binary, expectedContract: 0))
        await model.launch()
        #expect(model.launchBlock?.contains("Update the app") == true)
    }

    @Test func aMatchingContractLoadsPlotsAndShowsPendingSetupSteps() async throws {
        let fake = try FakeLoam([("version", 0), ("setup_check", 0), ("list", 0), ("list_archived", 0), ("changes", 0), ("worktree_list_empty", 0)])
        let state = AppStateFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString)/state.json"))
        let model = AppModel(client: fake.client(), stateFile: state)
        await model.launch(startFeed: false)
        #expect(model.launchBlock == nil)
        #expect(model.setupSteps.map(\.id) == ["mcp"])
        #expect(model.plots.count == 2)
        #expect(fake.args() == ["version --json", "setup --check --json", "list --json", "list --archived --json", "changes --json", "worktree list --json"])
    }

    @Test func aFailedSetupCheckShowsNoBannerAndStillLoads() async throws {
        let fake = try FakeLoam([("version", 0), ("error_generic", 1), ("list", 0)])
        let model = AppModel(client: fake.client())
        await model.launch(startFeed: false)
        #expect(model.setupSteps.isEmpty)
        #expect(model.plots.count == 2)
    }

    @Test func aMissingBinaryBlocks() async {
        let client = LoamClient(binary: URL(fileURLWithPath: "/nonexistent/loam"))
        let model = AppModel(client: client)
        await model.launch(startFeed: false)
        #expect(model.launchBlock?.contains("Run the install script") == true)
    }
}
