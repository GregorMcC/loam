/// What the model, effort, MCP, and code review controls of the run defaults hold.
public struct RunDefaultsChoice: Equatable, Sendable {
    public var model: String
    public var effort: String
    public var servers: [String]
    public var review: Bool
    public var reviewEffort: String

    public init(model: String, effort: String, servers: [String], review: Bool = true, reviewEffort: String = "") {
        self.model = model
        self.effort = effort
        self.servers = servers
        self.review = review
        self.reviewEffort = reviewEffort
    }

    public init(_ defaults: RunDefaults?) {
        self.init(model: defaults?.model ?? "", effort: defaults?.effort ?? "", servers: defaults?.mcpServers ?? [],
                  review: defaults?.review ?? true, reviewEffort: defaults?.reviewEffort ?? "")
    }

    /// True when a pick must be saved: the pickers hold the defaults of `plot`, as the core read them, and the pick
    /// differs from the last one that was saved or asked for. Before the read ends, the pickers are empty, and a save
    /// would overwrite the real defaults with empty values.
    public static func needsSave(_ now: RunDefaultsChoice, requested: RunDefaultsChoice, loaded: RunDefaults?, plot: String) -> Bool {
        loaded?.plotID == plot && now != requested
    }
}
