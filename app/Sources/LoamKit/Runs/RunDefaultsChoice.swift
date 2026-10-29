/// What the model, effort, and MCP pickers of the run defaults hold.
public struct RunDefaultsChoice: Equatable, Sendable {
    public var model: String
    public var effort: String
    public var servers: [String]

    public init(model: String, effort: String, servers: [String]) {
        self.model = model
        self.effort = effort
        self.servers = servers
    }

    public init(_ defaults: RunDefaults?) {
        self.init(model: defaults?.model ?? "", effort: defaults?.effort ?? "", servers: defaults?.mcpServers ?? [])
    }

    /// True when a pick must be saved: the pickers hold the defaults of `plot`, as the core read them, and the pick
    /// differs from the last one that was saved or asked for. Before the read ends, the pickers are empty, and a save
    /// would overwrite the real defaults with empty values.
    public static func needsSave(_ now: RunDefaultsChoice, requested: RunDefaultsChoice, loaded: RunDefaults?, plot: String) -> Bool {
        loaded?.plotID == plot && now != requested
    }
}
