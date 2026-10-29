import Testing

@testable import LoamKit

struct MCPChoicesTests {
    private let servers = [MCPServer(name: "docs", scope: "user"), MCPServer(name: "notes", scope: "user")]

    @Test func theLabelCountsTheServers() {
        #expect(MCPChoices.label(count: 0) == "No MCP servers")
        #expect(MCPChoices.label(count: 1) == "1 MCP server")
        #expect(MCPChoices.label(count: 2) == "2 MCP servers")
    }

    @Test func eachServerShowsItsScopeAndWhetherItIsSelected() {
        let items = MCPChoices.items(servers: servers, selected: ["notes"])
        #expect(items.map(\.title) == ["docs \u{00B7} user", "notes \u{00B7} user"])
        #expect(items.map(\.isSelected) == [false, true])
    }

    @Test func aSelectedServerThatTheListLacksStaysSelectedAndIsNotFound() {
        let items = MCPChoices.items(servers: servers, selected: ["gone", "docs"])
        #expect(items.map(\.title) == ["docs \u{00B7} user", "notes \u{00B7} user", "gone \u{00B7} not found"])
        #expect(items.last?.isMissing == true && items.last?.isSelected == true)
    }

    @Test func switchingAServerKeepsTheOthersInOrder() {
        #expect(MCPChoices.toggled("b", in: ["a", "b", "c"]) == ["a", "c"])
        #expect(MCPChoices.toggled("d", in: ["a"]) == ["a", "d"])
    }
}
