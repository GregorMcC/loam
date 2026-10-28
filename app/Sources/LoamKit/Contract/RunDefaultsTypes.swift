import Foundation

/// The model and the effort that a run of the plot gets when it names none. Empty is the default of Claude Code.
public struct RunDefaults: Codable, Equatable, Sendable {
    public var plotID: String
    public var model: String
    public var effort: String

    enum CodingKeys: String, CodingKey {
        case model, effort
        case plotID = "plot_id"
    }
}

/// Output of `loam run defaults`.
public struct RunDefaultsOne: Codable, Equatable, Sendable {
    public var defaults: RunDefaults
}
