import Foundation
import Observation

/// Settings > Connections (ticket 205): the Linear API key. The core keeps the key in the Keychain and checks it with
/// Linear. The app only sends a new key, on stdin, and never reads it back.
@MainActor
@Observable
public final class ConnectionsModel {
    @ObservationIgnored private let client: LoamClient
    /// The status of the key, as the core last read it. Nil before the first read.
    public private(set) var linear: LinearStatus?
    /// True while a command runs.
    public private(set) var isWorking = false
    /// Why the last change failed, or nil.
    public private(set) var error: String?

    public init(client: LoamClient) {
        self.client = client
    }

    /// The status in words for a person.
    public var linearWords: String {
        guard let linear else { return "Checking." }
        if !linear.connected { return "No Linear API key." }
        if let viewer = linear.viewer { return "Connected to \(viewer.organization) as \(viewer.name)." }
        return "A key is stored, but Linear did not answer: \(linear.error)"
    }

    /// Reads the status of the key.
    public func load() async {
        await work { try await self.client.linearStatus() }
    }

    /// Checks the key with Linear and stores it. Returns true when Linear took it.
    public func setLinearKey(_ key: String) async -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        return await work { try await self.client.linearSetKey(key) }
    }

    /// Removes the key.
    public func removeLinearKey() async {
        await work { try await self.client.linearRemoveKey() }
    }

    @discardableResult
    private func work(_ call: @escaping () async throws -> LinearStatus) async -> Bool {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            linear = try await call()
            return true
        } catch {
            self.error = AppModel.message(for: error)
            return false
        }
    }
}
