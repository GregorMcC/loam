import Foundation
import Testing

@testable import LoamKit

/// Ticket 205: Settings > Connections reads, sets, and removes the Linear API key through the core.
@MainActor
@Suite(.waitLimit) struct ConnectionsTests {
    @Test func loadsTheStatusOfTheKey() async throws {
        let fake = try FakeLoam([("linear_status", 0), ("linear_updates", 0), ("list", 0), ("show", 0)])
        let model = ConnectionsModel(client: fake.client())
        await model.load()
        #expect(model.linear?.viewer?.name == "Ada Example")
        #expect(model.linearWords == "Connected to Acme as Ada Example.")
        #expect(fake.args().first == "linear status --json")
    }

    @Test func setsTheKeyOnStdinAndRemovesIt() async throws {
        let fake = try FakeLoam([("linear_key_set", 0), ("linear_key_rm", 0)])
        let model = ConnectionsModel(client: fake.client())
        #expect(await model.setLinearKey("  lin_api_good \n"))
        #expect(model.linear?.connected == true)
        #expect(fake.args() == ["linear key set --json"])
        #expect((try? String(contentsOf: fake.stdinLog, encoding: .utf8))?.contains("lin_api_good") == true)
        await model.removeLinearKey()
        #expect(model.linear?.connected == false)
        #expect(model.linearWords == "No Linear API key.")
    }

    @Test func aRefusedKeySaysWhy() async throws {
        let fake = try FakeLoam([("error_generic", 1)])
        let model = ConnectionsModel(client: fake.client())
        #expect(await model.setLinearKey("lin_api_bad") == false)
        #expect(model.error?.isEmpty == false)
        // An empty key is not sent.
        #expect(await model.setLinearKey("  ") == false)
        #expect(fake.args().count == 1)
    }
}
