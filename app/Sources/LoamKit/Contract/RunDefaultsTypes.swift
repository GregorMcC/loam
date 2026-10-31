import Foundation

/// The model and the effort that a run of the plot gets when it names none. Empty is the default of Claude Code.
/// `mcpServers` names the MCP servers that a draft and the PR text load. Empty is none.
/// `review` is true when Loam runs a code review before it pushes a run, and `reviewEffort` is the effort of that
/// review. Empty is the default of Claude Code. An older core prints neither: the review is then on, with that default.
public struct RunDefaults: Codable, Equatable, Sendable {
    public var plotID: String
    public var model: String
    public var effort: String
    public var mcpServers: [String]
    public var review: Bool
    public var reviewEffort: String

    public init(plotID: String, model: String, effort: String, mcpServers: [String], review: Bool, reviewEffort: String) {
        self.plotID = plotID
        self.model = model
        self.effort = effort
        self.mcpServers = mcpServers
        self.review = review
        self.reviewEffort = reviewEffort
    }

    enum CodingKeys: String, CodingKey {
        case model, effort, review
        case plotID = "plot_id"
        case mcpServers = "mcp_servers"
        case reviewEffort = "review_effort"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plotID = try c.decode(String.self, forKey: .plotID)
        model = try c.decode(String.self, forKey: .model)
        effort = try c.decode(String.self, forKey: .effort)
        mcpServers = try c.decode([String].self, forKey: .mcpServers)
        review = try c.decodeIfPresent(Bool.self, forKey: .review) ?? true
        reviewEffort = try c.decodeIfPresent(String.self, forKey: .reviewEffort) ?? ""
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
