import Foundation

/// The Ghostty config files that Loam loads, and what Loam reads from them itself:
/// the `config-file` includes (to watch them) and the `keybind` lines (to find clashes).
/// libghostty parses the config. This type only finds the files and scans lines.
public struct GhosttyConfigFiles: Equatable, Sendable {
    /// Loam's own default files. They load first, so a value in your config overrides each one.
    /// Ticket 55 puts its `theme` line here.
    public var defaults: [String]
    /// Your Ghostty config files that exist, in Ghostty's load order.
    public var user: [String]

    public init(defaults: [String] = [], user: [String]) {
        self.defaults = defaults
        self.user = user
    }

    /// Every file, in load order. libghostty loads the `config-file` includes after these.
    public var loadOrder: [String] { defaults + user }

    // MARK: Ghostty's default files

    /// The files of Ghostty's default search, in its load order (`loadDefaultFiles` in
    /// `src/config/Config.zig` at the commit in ghostty.pin): the XDG `config`, the XDG
    /// `config.ghostty`, then the same two names in Application Support. A file can be missing.
    public static func defaultCandidates(environment: [String: String], home: String) -> [String] {
        let xdgHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        let appSupport = home + "/Library/Application Support/com.mitchellh.ghostty"
        return [
            xdgHome + "/ghostty/config",
            xdgHome + "/ghostty/config.ghostty",
            appSupport + "/config",
            appSupport + "/config.ghostty",
        ]
    }

    /// Your Ghostty config: the default candidates that exist.
    public static func userDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        defaultCandidates(environment: environment, home: home).filter(exists)
    }

    // MARK: Lines

    /// One `key = value` line of a Ghostty config file. `number` starts at 1.
    public struct Entry: Equatable, Sendable {
        public var file: String
        public var number: Int
        public var key: String
        public var value: String
    }

    /// The `key = value` lines of a file, as Ghostty reads them: a `#` comment only at the start
    /// of a line, spaces around `=` ignored, and one pair of double quotes around a value removed.
    public static func entries(in text: String, file: String) -> [Entry] {
        var result: [Entry] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            result.append(Entry(file: file, number: index + 1, key: key, value: value))
        }
        return result
    }

    /// The files that `config-file` lines include, as full paths. A relative path is relative
    /// to the folder of the file that includes it. A leading `?` (an optional file) is removed.
    public static func includes(in text: String, file: String, home: String = NSHomeDirectory()) -> [String] {
        let folder = (file as NSString).deletingLastPathComponent
        return entries(in: text, file: file).compactMap { entry in
            guard entry.key == "config-file" else { return nil }
            var path = entry.value
            if path.hasPrefix("?") { path.removeFirst() }
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
            guard !path.isEmpty else { return nil }
            if path.hasPrefix("~/") { path = home + path.dropFirst() }
            if !path.hasPrefix("/") { path = folder + "/" + path }
            return (path as NSString).standardizingPath
        }
    }

    /// Every file that a load reads, in order: the given files, then their includes (and the
    /// includes of those), each one once. `read` returns nil for a file that does not exist.
    public static func expand(_ files: [String], home: String = NSHomeDirectory(), read: (String) -> String?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var queue = files
        while !queue.isEmpty {
            let file = queue.removeFirst()
            guard seen.insert(file).inserted, let text = read(file) else { continue }
            result.append(file)
            queue += includes(in: text, file: file, home: home)
        }
        return result
    }

    // MARK: Clashes

    /// A `keybind` line in your config that binds one of Loam's fixed keys.
    public struct Clash: Equatable, Sendable, CustomStringConvertible {
        public var key: FixedKey
        public var entry: Entry

        /// The line Loam logs.
        public var description: String {
            "Ghostty config \(entry.file) line \(entry.number): keybind = \(entry.value) uses \(key.chord). "
                + "Loam uses \(key.chord) for \(key.title), so Loam's key wins."
        }
    }

    /// The `keybind` lines that bind a fixed Loam key (spec 8.3). A line that unbinds the key, or
    /// binds it to the Ghostty action that the Loam key stands for, is no clash.
    /// The first key of a sequence counts: Loam takes that key, so the sequence cannot start.
    public static func clashes(in entries: [Entry]) -> [Clash] {
        entries.compactMap { entry in
            guard entry.key == "keybind", let binding = Keybind(entry.value) else { return nil }
            guard let fixed = LoamKeys.fixedKey(for: binding.firstChord) else { return nil }
            if binding.action == "unbind" { return nil }
            if !binding.isSequence, let same = fixed.ghosttyAction, binding.action == same { return nil }
            return Clash(key: fixed, entry: entry)
        }
    }

    /// The parts of one `keybind` value that a clash needs.
    struct Keybind {
        var firstChord: KeyChord
        var isSequence: Bool
        var action: String

        /// Follows `Parser.init` in Ghostty's `src/input/Binding.zig`: the prefixes `all:`,
        /// `global:`, `unconsumed:`, and `performable:`, then the trigger up to the first `=`
        /// that is not followed by `+` or `=`, then the action.
        init?(_ value: String) {
            var input = Substring(value)
            while let colon = input.firstIndex(of: ":"),
                  ["all", "global", "unconsumed", "performable"].contains(String(input[..<colon])) {
                input = input[input.index(after: colon)...]
            }
            guard input != "clear", !input.hasPrefix("chain=") else { return nil }
            var split: Substring.Index?
            var index = input.startIndex
            while index < input.endIndex {
                if input[index] == "=" {
                    let next = input.index(after: index)
                    if next < input.endIndex, input[next] == "+" || input[next] == "=" {
                        index = next
                        continue
                    }
                    split = index
                    break
                }
                index = input.index(after: index)
            }
            guard let split else { return nil }
            let trigger = input[..<split]
            let first = trigger.split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false)
            guard let chord = first.first.flatMap({ KeyChord.ghosttyTrigger(String($0)) }) else { return nil }
            firstChord = chord
            isSequence = first.count > 1
            action = String(input[input.index(after: split)...]).trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: Watch

    /// What to watch for a change to the config files.
    public struct WatchPlan: Equatable, Sendable {
        /// Folders that exist and hold a config file, or the file that a link points to.
        /// FSEvents watches each one with its subfolders, so a theme in `themes` counts too.
        public var folders: [String] = []
        /// For a config file whose folder does not exist yet: the nearest folder that exists.
        /// Loam watches only the entries of this folder, with no subfolders, so a write
        /// elsewhere under it (in `~` or Application Support) does not wake the app.
        /// When a missing folder appears, the plan changes.
        public var parents: [String] = []
    }

    /// The watch plan for `files`. A config made after launch (⌘, makes one) is still seen:
    /// its folder is watched, or the nearest folder that exists until its folder appears.
    public static func watchPlan(
        for files: [String], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> WatchPlan {
        var plan = WatchPlan()
        var missing: [String] = []
        for file in files {
            for path in [file, (file as NSString).resolvingSymlinksInPath] {
                let folder = (path as NSString).deletingLastPathComponent
                if exists(folder) {
                    if !plan.folders.contains(folder) { plan.folders.append(folder) }
                } else if !missing.contains(folder) {
                    missing.append(folder)
                }
            }
        }
        for var folder in missing {
            while !exists(folder), folder != "/", !folder.isEmpty {
                folder = (folder as NSString).deletingLastPathComponent
            }
            guard exists(folder), !plan.folders.contains(folder), !plan.parents.contains(folder) else { continue }
            plan.parents.append(folder)
        }
        return plan
    }
}

/// The event filter of the config watch: true when a file event at a path can change the config.
/// That is a write to one of the files (or to the file that a link points to), or to a theme in
/// the `themes` folder beside one of them. It finds the real paths of the files once, so each
/// event needs only string checks and no file system call. The watch makes it again after each
/// config event, so a file that becomes a link is followed.
public struct ConfigEventFilter: Equatable, Sendable {
    private let files: Set<String>
    private let folders: Set<String>

    public init(files: [String]) {
        let names = files.flatMap(Self.names(of:))
        self.files = Set(names)
        self.folders = Set(names.map { ($0 as NSString).deletingLastPathComponent })
    }

    /// True for one of the files, or for a file in the `themes` folder beside one of them.
    public func accepts(_ path: String) -> Bool {
        if files.contains(path) { return true }
        let parent = (path as NSString).deletingLastPathComponent
        guard (parent as NSString).lastPathComponent == "themes" else { return false }
        return folders.contains((parent as NSString).deletingLastPathComponent)
    }

    /// The names an event can use for `path`: the path as given, with links resolved, and the
    /// real path. FSEvents reports real paths (`/private/var`, where `/var` is a link). A file
    /// that does not exist yet gets the real path of its nearest folder that exists.
    static func names(of path: String) -> [String] {
        var names = [path, (path as NSString).resolvingSymlinksInPath]
        var head = path
        var tail: [String] = []
        while !head.isEmpty, head != "/" {
            if let real = realPath(head) {
                names.append(([real] + tail.reversed()).joined(separator: "/"))
                break
            }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
