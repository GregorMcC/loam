import Foundation
import Observation

/// The three lists of the sandbox settings.
public enum SandboxList: String, CaseIterable, Sendable {
    case read, write, hosts

    public var title: String {
        switch self {
        case .read: "Read paths"
        case .write: "Write paths"
        case .hosts: "Hosts"
        }
    }

    /// What the list lets a run do, in one line.
    public var caption: String {
        switch self {
        case .read: "Folders that a run can read, such as a toolchain."
        case .write: "Folders that a run can write and read, such as a cache."
        case .hosts: "Hosts that a run can reach. A name, or *. and a name."
        }
    }

    public var placeholder: String {
        switch self {
        case .read, .write: "~/.nvm"
        case .hosts: "registry.example.com"
        }
    }

    func items(of settings: SandboxSettings) -> [String] {
        switch self {
        case .read: settings.read
        case .write: settings.write
        case .hosts: settings.hosts
        }
    }
}

/// The paths and hosts that you add to the sandbox of a run, for one plot or for the whole machine. The core checks
/// each item and refuses one that opens your home folder. The model keeps the settings that the core last gave, and
/// the reason for the last change that the core refused.
@MainActor
@Observable
public final class SandboxSettingsModel {
    @ObservationIgnored private let client: LoamClient
    /// The plot, or nil for the machine scope.
    public let plot: String?
    /// The settings as the core last gave them. Nil before the first read.
    public private(set) var settings: SandboxSettings?
    /// Why the last read or change failed, or nil.
    public private(set) var error: String?

    public init(client: LoamClient, plot: String? = nil) {
        self.client = client
        self.plot = plot
    }

    public func load() async {
        do {
            settings = try await client.sandboxSettings(plot: plot)
            error = nil
        } catch {
            self.error = AppModel.message(for: error)
        }
    }

    public func items(_ list: SandboxList) -> [String] {
        settings.map(list.items(of:)) ?? []
    }

    /// Adds an item to a list. It returns true when the core saved it, or when the list has it. A refused item stays
    /// out of the list, and `error` says why.
    @discardableResult
    public func add(_ list: SandboxList, _ text: String) async -> Bool {
        let item = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.isEmpty, let current = settings else { return false }
        guard !list.items(of: current).contains(item) else { return true }
        return await save(list, list.items(of: current) + [item])
    }

    public func remove(_ list: SandboxList, _ item: String) async {
        guard let current = settings else { return }
        await save(list, list.items(of: current).filter { $0 != item })
    }

    private func save(_ list: SandboxList, _ items: [String]) async -> Bool {
        do {
            settings = try await client.setSandboxList(plot: plot, list, items)
            error = nil
            return true
        } catch {
            self.error = AppModel.message(for: error)
            return false
        }
    }
}
