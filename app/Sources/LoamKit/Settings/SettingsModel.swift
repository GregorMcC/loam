import Foundation
import Observation

/// The settings window's model (ticket 81). It holds the settings file, writes each change at
/// once, and reads the file again when it changes on disk.
@MainActor
@Observable
public final class SettingsModel {
    /// What a run of the `loam` binary said.
    public enum LoamStatus: Equatable, Sendable {
        case checking
        case ok(version: String, contract: Int)
        case failed(String)
    }

    @ObservationIgnored public let file: SettingsFile
    public private(set) var settings: LoamSettings
    /// Why the file could not be read or written. Nil when all is well.
    public private(set) var fileError: String?
    public private(set) var loamStatus: LoamStatus = .checking
    /// The `loam` binary that this launch runs. A different setting applies at the next launch.
    @ObservationIgnored public let launchBinary: String
    /// Called after each change, from the window or from the file.
    @ObservationIgnored public var onChange: (@MainActor (LoamSettings) -> Void)?

    @ObservationIgnored private let home: String
    @ObservationIgnored private let resolver: @Sendable (String?) -> LoamBinary.Resolution
    @ObservationIgnored private let checker: @Sendable (String) async -> LoamStatus
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    public init(
        file: SettingsFile,
        launchBinary: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        resolve: @escaping @Sendable (String?) -> LoamBinary.Resolution = { LoamBinary.resolve(setting: $0) },
        check: @escaping @Sendable (String) async -> LoamStatus = SettingsModel.checkContract
    ) {
        self.file = file
        self.launchBinary = launchBinary
        self.home = home
        resolver = resolve
        checker = check
        let load = file.read()
        settings = load.settings
        fileError = load.error
    }

    /// The repo folders with `~` expanded.
    public var repoFolderPaths: [String] { settings.expandedRepoFolders(home: home) }

    /// The `loam` binary that the setting gives now.
    public var loam: LoamBinary.Resolution { resolver(settings.loamPath) }

    /// True when the setting gives another binary than the one this launch runs.
    public var needsRestart: Bool { loam.path != launchBinary }

    /// A path in the home folder, written with `~`, for display.
    public func display(_ path: String) -> String { SettingsPath.abbreviate(path, home: home) }

    // MARK: Changes

    public func addRepoFolder(_ path: String) {
        let entry = SettingsPath.abbreviate(path, home: home)
        guard !settings.repoFolders.contains(entry) else { return }
        var next = settings
        next.repoFolders.append(entry)
        save(next)
    }

    public func removeRepoFolders(_ entries: Set<String>) {
        var next = settings
        next.repoFolders.removeAll { entries.contains($0) }
        save(next)
    }

    /// Nil sets Automatic. A path in the home folder is written with `~`.
    public func setLoamPath(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = settings
        next.loamPath = trimmed.flatMap { $0.isEmpty ? nil : SettingsPath.abbreviate($0, home: home) }
        save(next)
    }

    private func save(_ next: LoamSettings) {
        guard next != settings else { return }
        do {
            try file.write(next)
            fileError = nil
        } catch SettingsFile.WriteError.invalidFile {
            fileError = "The settings file does not hold a JSON object. Fix the file, then change the setting again."
            return
        } catch {
            fileError = "Loam could not write the settings file: \(error.localizedDescription)"
            return
        }
        settings = next
        onChange?(next)
    }

    // MARK: The file on disk

    /// Reads the file again. A change calls `onChange`. A file that is now invalid keeps the last
    /// good settings, so a typo in a hand edit does not reset them.
    public func reload() {
        let load = file.read()
        fileError = load.error
        guard load.error == nil, load.settings != settings else { return }
        settings = load.settings
        onChange?(load.settings)
    }

    /// Reads the file again after each write to it, so a hand edit applies at once.
    public func startWatching() {
        watchTask?.cancel()
        let events = DirectoryWatcher.events(at: file.url.deletingLastPathComponent(), onlyFiles: [SettingsFile.name])
        watchTask = Task { [weak self] in
            for await _ in events {
                guard let self, !Task.isCancelled else { return }
                self.reload()
            }
        }
    }

    public func stopWatching() { watchTask?.cancel() }

    // MARK: The loam check

    /// Runs the binary that the setting gives and keeps what it said.
    public func checkLoam() async {
        let path = loam.path
        loamStatus = .checking
        let status = await checker(path)
        // A newer setting started its own check.
        guard path == loam.path else { return }
        loamStatus = status
    }

    /// `loam version --json`, and the contract version check.
    public nonisolated static func checkContract(_ path: String) async -> LoamStatus {
        do {
            let info = try await LoamClient(binary: URL(fileURLWithPath: path)).checkContract()
            return .ok(version: info.version, contract: info.contractVersion)
        } catch let error as LoamError {
            return .failed(error.userMessage)
        } catch {
            return .failed(String(describing: error))
        }
    }
}
