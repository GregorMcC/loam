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
        let fake = try FakeLoam([("run_sandbox_get", 0), ("run_sandbox_get", 0), ("run_sandbox_machine", 0)])
        let model = SandboxSettingsModel(client: fake.client())
        await model.load()
        #expect(await model.add(.read, "  ~/.nvm \n"))
        #expect(model.items(.read) == ["~/.nvm"])
        #expect(model.items(.hosts) == ["registry.example.com"])
        #expect(model.error == nil)
        #expect(fake.args() == ["run sandbox --json", "run sandbox --json", "run sandbox --read ~/.nvm --json"])
    }

    @Test func anEmptyItemAndARepeatCallNothing() async throws {
        let fake = try FakeLoam([("run_sandbox_machine", 0)])
        let model = SandboxSettingsModel(client: fake.client())
        await model.load()
        #expect(await !model.add(.read, "   "))
        // The list has it: the model reads again and writes nothing.
        #expect(await model.add(.read, "~/.nvm"))
        #expect(fake.args() == ["run sandbox --json", "run sandbox --json"])
    }

    @Test func anItemThatTheCoreRefusesStaysOutAndSaysWhy() async throws {
        let fake = try FakeLoam([("run_sandbox_get", 0), ("run_sandbox_get", 0), ("error_run_sandbox_opens_home", 2)])
        let model = SandboxSettingsModel(client: fake.client())
        await model.load()
        #expect(await !model.add(.read, "~/.ssh"))
        #expect(model.items(.read).isEmpty)
        #expect(model.error?.contains("is not allowed") == true)
        #expect(model.errorList == .read)
    }

    @Test func aFailedReadStopsTheChange() async throws {
        let fake = try FakeLoam([("run_sandbox_get", 0), ("error_run_sandbox_opens_home", 2)])
        let model = SandboxSettingsModel(client: fake.client())
        await model.load()
        #expect(await !model.add(.read, "~/.nvm"))
        await model.remove(.read, "~/.nvm")
        // Only the two reads ran. Neither change wrote a list from the old value.
        #expect(fake.args().allSatisfy { !$0.contains("--read") })
        #expect(model.error != nil)
    }

    @Test func aRemovedItemSendsOnlyItsOwnList() async throws {
        let fake = try FakeLoam([("run_sandbox_machine", 0), ("run_sandbox_machine", 0), ("run_sandbox_clear", 0)])
        let model = SandboxSettingsModel(client: fake.client(), plot: "plotaaaaab")
        await model.load()
        await model.remove(.read, "~/.nvm")
        // Only the read list goes to the core, so a change of another list by someone else stays.
        #expect(fake.args().last == "run sandbox --read  --json -- plotaaaaab")
        #expect(model.items(.read).isEmpty)
    }

    /// Two changes of one list at once work one after the other, so the second starts from what the first saved.
    @Test func twoChangesOfOneListRunInOrder() async throws {
        let fake = try FakeLoam([("run_sandbox_get", 0), ("run_sandbox_get", 0), ("run_sandbox_machine", 0),
                                 ("run_sandbox_machine", 0), ("run_sandbox_clear", 0)])
        let model = SandboxSettingsModel(client: fake.client())
        await model.load()
        async let first = model.add(.read, "~/.nvm")
        async let second: Void = model.remove(.read, "~/.nvm")
        _ = await (first, second)
        #expect(fake.args() == ["run sandbox --json", "run sandbox --json", "run sandbox --read ~/.nvm --json",
                                "run sandbox --json", "run sandbox --read  --json"])
        #expect(model.items(.read).isEmpty)
    }
}
