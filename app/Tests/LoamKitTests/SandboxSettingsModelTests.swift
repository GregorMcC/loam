import Foundation
import Testing

@testable import LoamKit

/// Settings > Runs and the run defaults of a plot: the paths and hosts that you add to the sandbox.
@MainActor
@Suite(.waitLimit) struct SandboxSettingsModelTests {
    @Test func loadReadsTheScope() async throws {
        let fake = try FakeLoam([("run_sandbox_get", 0)])
        let model = SandboxSettingsModel(client: fake.client(), plot: "plotaaaaab")
        #expect(model.settings == nil)
        await model.load()
        #expect(model.settings == SandboxSettings())
        #expect(SandboxList.allCases.allSatisfy { model.items($0).isEmpty })
        #expect(fake.args() == ["run sandbox --json -- plotaaaaab"])
    }

    @Test func anItemIsAddedToItsListAndTheCoreAnswerIsKept() async throws {
        let fake = try FakeLoam([("run_sandbox_get", 0), ("run_sandbox_machine", 0)])
        let model = SandboxSettingsModel(client: fake.client())
        await model.load()
        #expect(await model.add(.read, "  ~/.nvm \n"))
        #expect(model.items(.read) == ["~/.nvm"])
        #expect(model.items(.hosts) == ["registry.example.com"])
        #expect(model.error == nil)
        #expect(fake.args() == ["run sandbox --json", "run sandbox --read ~/.nvm --json"])
    }

    @Test func anEmptyItemAndARepeatCallNothing() async throws {
        let fake = try FakeLoam([("run_sandbox_machine", 0)])
        let model = SandboxSettingsModel(client: fake.client())
        await model.load()
        #expect(await !model.add(.read, "   "))
        #expect(await model.add(.read, "~/.nvm"))
        let calls = fake.args().count
        #expect(await model.add(.read, "~/.nvm"))
        #expect(fake.args().count == calls)
    }

    @Test func anItemThatTheCoreRefusesStaysOutAndSaysWhy() async throws {
        let fake = try FakeLoam([("run_sandbox_get", 0), ("error_run_sandbox_opens_home", 2)])
        let model = SandboxSettingsModel(client: fake.client())
        await model.load()
        #expect(await !model.add(.read, "~/.ssh"))
        #expect(model.items(.read).isEmpty)
        #expect(model.error?.contains("is not allowed") == true)
    }

    @Test func aRemovedItemSendsOnlyItsOwnList() async throws {
        let fake = try FakeLoam([("run_sandbox_machine", 0), ("run_sandbox_clear", 0)])
        let model = SandboxSettingsModel(client: fake.client(), plot: "plotaaaaab")
        await model.load()
        await model.remove(.read, "~/.nvm")
        // Only the read list goes to the core, so a change of another list by someone else stays.
        #expect(fake.args().last == "run sandbox --read  --json -- plotaaaaab")
        #expect(model.items(.read).isEmpty)
    }
}
