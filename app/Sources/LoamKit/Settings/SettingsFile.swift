import Foundation

/// The settings that differ from one machine to the next (ADR 0006, docs/contract.md).
public struct LoamSettings: Equatable, Sendable {
    /// The folders whose git checkouts the add repo row offers. Paths keep `~` as written.
    public var repoFolders: [String]
    /// The `loam` binary. Nil means Automatic (`LoamBinary.resolve`).
    public var loamPath: String?

    public init(repoFolders: [String], loamPath: String?) {
        self.repoFolders = repoFolders
        self.loamPath = loamPath
    }

    public static let defaults = LoamSettings(repoFolders: ["~/Development"], loamPath: nil)

    public func expandedRepoFolders(home: String) -> [String] {
        repoFolders.map { SettingsPath.expand($0, home: home) }
    }
}

/// `~` in a settings path.
public enum SettingsPath {
    /// Expands `~` and `~/…`. Any other path stays as it is.
    public static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    /// Writes a path in the home folder with `~`, so the file works on another machine.
    public static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// `<LOAM_HOME>/settings.json`. Every write reads the whole file and changes only the keys of
/// `LoamSettings`, so keys that the app does not know stay as they are. A file that holds invalid
/// JSON is never replaced.
public struct SettingsFile: Sendable {
    public static let name = "settings.json"
    static let repoFoldersKey = "repo_folders"
    static let loamPathKey = "loam_path"

    public let url: URL

    public init(url: URL) { self.url = url }

    /// The file in `LOAM_HOME`, or in `~/.loam`.
    public init(environment: [String: String] = [:]) {
        url = DirectoryWatcher.home(environment: environment).appendingPathComponent(Self.name)
    }

    /// The settings, and the reason the file could not be read. A missing file is no error.
    public struct Load: Equatable, Sendable {
        public var settings: LoamSettings
        public var error: String?
    }

    public enum WriteError: Error, Equatable { case invalidFile }

    /// A missing file or key gives the default. Invalid JSON gives the defaults and an error.
    public func read() -> Load {
        guard let data = try? Data(contentsOf: url) else { return Load(settings: .defaults, error: nil) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Load(settings: .defaults, error: "The settings file does not hold a JSON object. Loam uses the defaults until you fix it.")
        }
        var settings = LoamSettings.defaults
        if let folders = object[Self.repoFoldersKey] as? [String] { settings.repoFolders = folders }
        if let path = object[Self.loamPathKey] as? String, !path.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.loamPath = path
        }
        return Load(settings: settings, error: nil)
    }

    /// Writes the settings and keeps the other keys. Throws `WriteError.invalidFile` when the file
    /// holds invalid JSON.
    public func write(_ settings: LoamSettings) throws {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw WriteError.invalidFile
            }
            object = existing
        }
        object[Self.repoFoldersKey] = settings.repoFolders
        object[Self.loamPathKey] = settings.loamPath ?? NSNull()
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Finds the `loam` binary that the app runs.
public enum LoamBinary {
    /// The places that Automatic tries before the PATH: the install script, then Homebrew.
    public static let installPaths = ["~/.local/bin/loam", "/opt/homebrew/bin/loam", "/usr/local/bin/loam"]

    public struct Resolution: Equatable, Sendable {
        public var path: String
        /// True when no custom path is set.
        public var automatic: Bool
        /// True when the path is an executable file.
        public var found: Bool

        public init(path: String, automatic: Bool, found: Bool) {
            self.path = path
            self.automatic = automatic
            self.found = found
        }
    }

    /// The loam CLI that a release puts in the app bundle (`scripts/build-app.sh --cli`).
    public static var bundledPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/loam").path
    }

    /// A custom path wins, found or not. Automatic tries `installPaths`, then the CLI in the app
    /// bundle, then each PATH folder. When nothing is found, it gives the first install path, so
    /// the error names it.
    public static func resolve(
        setting: String?,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        pathVariable: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        bundled: String = bundledPath,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Resolution {
        if let setting {
            let path = SettingsPath.expand(setting, home: home)
            return Resolution(path: path, automatic: false, found: isExecutable(path))
        }
        let installs = installPaths.map { SettingsPath.expand($0, home: home) }
        let onPath = pathVariable.split(separator: ":").map { "\($0)/loam" }
        if let found = (installs + [bundled] + onPath).first(where: isExecutable) {
            return Resolution(path: found, automatic: true, found: true)
        }
        return Resolution(path: installs[0], automatic: true, found: false)
    }
}
