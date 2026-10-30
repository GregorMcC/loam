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
        case .hosts: "Hosts that a run can reach: a name such as registry.example.com, or *.example.com for all its subdomains."
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
    /// The list of the last change that failed, or nil when the failure was a read.
    public private(set) var errorList: SandboxList?
    /// The end of the queue of reads and changes. Each one waits for the one before it, so a change never works from
    /// a list that the one before it is still changing.
    @ObservationIgnored private var tail: Task<Void, Never>?

    public init(client: LoamClient, plot: String? = nil) {
        self.client = client
        self.plot = plot
    }

    private func serial<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await body()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    public func load() async {
        await serial { [self] in
            await read()
        }
    }

    private func read() async {
        do {
            settings = try await client.sandboxSettings(plot: plot)
            error = nil
            errorList = nil
        } catch {
            self.error = AppModel.message(for: error)
            errorList = nil
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
        guard !item.isEmpty, settings != nil else { return false }
        return await serial { [self] in
            // Read the list again, so an item that the CLI added since the last read stays.
            await read()
            guard let current = settings else { return false }
            guard !list.items(of: current).contains(item) else { return true }
            return await save(list, list.items(of: current) + [item])
        }
    }

    public func remove(_ list: SandboxList, _ item: String) async {
        guard settings != nil else { return }
        await serial { [self] in
            await read()
            guard let current = settings else { return }
            await save(list, list.items(of: current).filter { $0 != item })
        }
    }

    @discardableResult
    private func save(_ list: SandboxList, _ items: [String]) async -> Bool {
        do {
            settings = try await client.setSandboxList(plot: plot, list, items)
            error = nil
            errorList = nil
            return true
        } catch {
            self.error = AppModel.message(for: error)
            errorList = list
            return false
        }
    }
}
