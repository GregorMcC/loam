import Foundation

/// The model and the effort that a run of the plot gets when it names none. Empty is the default of Claude Code.
/// `mcpServers` names the MCP servers that a draft and the PR text load. Empty is none.
public struct RunDefaults: Codable, Equatable, Sendable {
    public var plotID: String
    public var model: String
    public var effort: String
    public var mcpServers: [String]

    enum CodingKeys: String, CodingKey {
        case model, effort
        case plotID = "plot_id"
        case mcpServers = "mcp_servers"
    }
}

/// An MCP server that `loam run defaults --mcp` can select.
public struct MCPServer: Codable, Equatable, Sendable {
    public var name: String
    /// The scope of the Claude Code config that holds the server. Only "user" for now.
    public var scope: String
}

/// Output of `loam run mcp-servers`.
public struct MCPServerList: Codable, Equatable, Sendable {
    public var servers: [MCPServer]
}

/// Output of `loam run defaults`.
public struct RunDefaultsOne: Codable, Equatable, Sendable {
    public var defaults: RunDefaults
}
