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
    /// The switches for the updates that Loam makes to Linear. Nil before the first read.
    public private(set) var updates: LinearUpdates?
    /// The row of each plot in "What each plot reads".
    public private(set) var scopeRows: [PlotScopeRow] = []
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

    /// The Account row: the person and the workspace of the key, or nil with no key.
    public var accountWords: String? {
        guard let viewer = linear?.viewer else { return nil }
        return "\(viewer.name) \u{B7} workspace \(viewer.organization)"
    }

    /// The mask of a stored key. The app never reads the key, so the mask has no real character of it.
    public static let keyMask = "lin_api_\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"

    /// Reads the status of the key, the switches, and the Linear scope of each plot.
    public func load() async {
        await work { try await self.client.linearStatus() }
        do {
            updates = try await client.linearUpdates()
            var plots: [Plot] = []
            for summary in try await client.list() where !summary.archived {
                plots.append(try await client.show(plot: summary.id))
            }
            scopeRows = PlotScopeRow.rows(plots: plots)
        } catch {
            self.error = AppModel.message(for: error)
        }
    }

    /// Sets one switch. The core answers with all four.
    public func setUpdate(_ keyPath: WritableKeyPath<LinearUpdates, Bool>, _ on: Bool) async {
        guard var next = updates, next[keyPath: keyPath] != on else { return }
        next[keyPath: keyPath] = on
        let old = updates
        updates = next  // Shows the new value at once. A failure puts the old one back.
        do {
            updates = try await client.setLinearUpdates(
                inProgress: keyPath == \.inProgress ? on : nil, attachPR: keyPath == \.attachPR ? on : nil,
                done: keyPath == \.done ? on : nil, walkthroughComment: keyPath == \.walkthroughComment ? on : nil)
            error = nil
        } catch {
            updates = old
            self.error = AppModel.message(for: error)
        }
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
