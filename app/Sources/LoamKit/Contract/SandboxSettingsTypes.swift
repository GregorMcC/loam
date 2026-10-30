import Foundation

/// The paths and hosts that you add to the sandbox of a run, on top of the stack presets. An empty `plotID` is the
/// machine scope, which holds for the runs of every plot. A write path is also a read path.
public struct SandboxSettings: Codable, Equatable, Sendable {
    public var plotID: String
    /// Paths the sandbox can read: absolute, or starting with `~/`.
    public var read: [String]
    /// Paths the sandbox can write and read.
    public var write: [String]
    /// Hosts the sandbox can reach: a DNS name, or `*.` and a name.
    public var hosts: [String]

    public init(plotID: String = "", read: [String] = [], write: [String] = [], hosts: [String] = []) {
        self.plotID = plotID
        self.read = read
        self.write = write
        self.hosts = hosts
    }

    enum CodingKeys: String, CodingKey {
        case read, write, hosts
        case plotID = "plot_id"
    }
}

/// Output of `loam run sandbox`.
public struct SandboxSettingsOne: Codable, Equatable, Sendable {
    public var sandbox: SandboxSettings
}
