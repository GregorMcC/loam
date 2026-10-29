/// The MCP servers of the picker for the run defaults: the servers that `--mcp` can select, and any selected server
/// that the list no longer returns.
public enum MCPChoices {
    public struct Item: Equatable, Sendable, Identifiable {
        public var name: String
        /// The scope of the server, or nil when the list does not return it.
        public var scope: String?
        public var isSelected: Bool
        public var id: String { name }
        public var isMissing: Bool { scope == nil }

        /// The title in the menu: the name and its scope, or "not found".
        public var title: String { "\(name) \u{00B7} \(scope ?? "not found")" }
    }

    /// The label of the menu button.
    public static func label(count: Int) -> String {
        count == 0 ? "No MCP servers" : "\(count) MCP \(count == 1 ? "server" : "servers")"
    }

    /// The items of the menu: each listed server, then each selected server that the list lacks, which stays selected
    /// until you clear it.
    public static func items(servers: [MCPServer], selected: [String]) -> [Item] {
        let listed = Set(servers.map(\.name))
        return servers.map { Item(name: $0.name, scope: $0.scope, isSelected: selected.contains($0.name)) }
            + selected.filter { !listed.contains($0) }.map { Item(name: $0, scope: nil, isSelected: true) }
    }

    /// The names after you switch one server. The order of the other names stays.
    public static func toggled(_ name: String, in selected: [String]) -> [String] {
        selected.contains(name) ? selected.filter { $0 != name } : selected + [name]
    }
}
