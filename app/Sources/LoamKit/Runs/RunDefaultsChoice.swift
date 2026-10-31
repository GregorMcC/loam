/// The run defaults to save: nil leaves a field as the core has it. The core sets only the flags that it gets, so a
/// save of one field cannot undo a change of another field that was made elsewhere, such as in the CLI.
public struct RunDefaultsChange: Equatable, Sendable {
    public var model: String?
    public var effort: String?
    public var servers: [String]?
    public var review: Bool?
    public var reviewEffort: String?

    public init(model: String? = nil, effort: String? = nil, servers: [String]? = nil, review: Bool? = nil,
                reviewEffort: String? = nil) {
        self.model = model
        self.effort = effort
        self.servers = servers
        self.review = review
        self.reviewEffort = reviewEffort
    }

    /// This change with `newer` on top: each field that `newer` sets replaces this one.
    func overlaid(by newer: RunDefaultsChange) -> RunDefaultsChange {
        RunDefaultsChange(
            model: newer.model ?? model, effort: newer.effort ?? effort, servers: newer.servers ?? servers,
            review: newer.review ?? review, reviewEffort: newer.reviewEffort ?? reviewEffort)
    }
}

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

    /// The fields of this pick that differ from `saved`. The others are nil.
    public func change(from saved: RunDefaultsChoice) -> RunDefaultsChange {
        RunDefaultsChange(
            model: model == saved.model ? nil : model, effort: effort == saved.effort ? nil : effort,
            servers: servers == saved.servers ? nil : servers, review: review == saved.review ? nil : review,
            reviewEffort: reviewEffort == saved.reviewEffort ? nil : reviewEffort)
    }

    /// True when a pick must be saved: the pickers hold the defaults of their plot, as the core read them, and the
    /// pick differs from the last one that was saved or asked for. Before the read ends, the pickers are empty, and a
    /// save would overwrite the real defaults with empty values. The page knows when its read ended: the shared
    /// `runDefaults` of the model can hold another plot, such as after a failed save of that plot.
    public static func needsSave(_ now: RunDefaultsChoice, requested: RunDefaultsChoice, isLoaded: Bool) -> Bool {
        isLoaded && now != requested
    }
}
