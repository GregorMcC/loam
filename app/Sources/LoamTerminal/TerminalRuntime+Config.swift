import AppKit
import GhosttyKit
import LoamKit
import OSLog

let configLog = Logger(subsystem: "dev.loam.Loam", category: "config")

/// What one Ghostty config load did.
public struct ConfigLoad: Sendable {
    public var outcome: ConfigOutcome
    /// Your config files that the load read, with their includes, in order.
    public var files: [String]
    /// The files that the watch covers: the files above, Loam's defaults, and the default
    /// files that do not exist yet.
    public var watchedFiles: [String]
    /// The `keybind` lines that bind a fixed Loam key. Loam's key wins over each one.
    public var clashes: [GhosttyConfigFiles.Clash]

    public var errors: [String] { outcome.errors }
}

/// The window appearance options of the Ghostty config (spec 8.3).
public struct WindowAppearance: Equatable {
    public var background: NSColor
    public var opacity: Double
    /// 0 is no blur. A negative value is a macOS glass style.
    public var blur: Int16
    /// native, transparent, tabs, or hidden.
    public var titlebarStyle: String
    /// auto, system, light, dark, or ghostty.
    public var windowTheme: String
    /// The terminal background in sRGB, as libghostty resolved it (the theme for Night or Day).
    /// Nil when the config has none. The chrome follows it (ticket 68).
    public var terminalBackground: UInt32?
}

extension TerminalRuntime {
    struct RawLoad {
        var config: ghostty_config_t
        var errors: [String]
        var files: [String]
        var watchedFiles: [String]
        var clashes: [GhosttyConfigFiles.Clash]
    }

    /// Loads Loam's defaults, then your files, then their `config-file` includes. Last wins.
    func loadConfigFiles() -> RawLoad {
        let config: ghostty_config_t = ghostty_config_new()
        let environment = ProcessInfo.processInfo.environment
        let user = source.user ?? GhosttyConfigFiles.userDefault(environment: environment)
        for file in GhosttyConfigFiles(defaults: source.defaults, user: user).loadOrder {
            ghostty_config_load_file(config, file)
        }
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        let errors = (0..<ghostty_config_diagnostics_count(config)).map {
            String(cString: ghostty_config_get_diagnostic(config, $0).message)
        }

        let read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
        let files = GhosttyConfigFiles.expand(user, read: read)
        let entries = files.flatMap { GhosttyConfigFiles.entries(in: read($0) ?? "", file: $0) }
        let candidates = source.user ?? GhosttyConfigFiles.defaultCandidates(environment: environment, home: NSHomeDirectory())
        var watched: [String] = []
        for file in source.defaults + candidates + files where !watched.contains(file) { watched.append(file) }
        return RawLoad(config: config, errors: errors, files: files, watchedFiles: watched,
                       clashes: GhosttyConfigFiles.clashes(in: entries))
    }

    func finishLoad(_ load: RawLoad, outcome: ConfigOutcome) -> ConfigLoad {
        switch outcome {
        case .applied:
            configLog.info("Ghostty config loaded from \(load.files.joined(separator: ", "), privacy: .public)")
        case .appliedWithErrors(let errors):
            configLog.warning("Ghostty config has errors. Loam uses the lines with no error: \(errors.joined(separator: "; "), privacy: .public)")
        case .keptLastGood(let errors):
            configLog.warning("Ghostty config has errors. Loam keeps the last good config: \(errors.joined(separator: "; "), privacy: .public)")
        }
        for clash in load.clashes { configLog.notice("\(clash.description, privacy: .public)") }
        return ConfigLoad(outcome: outcome, files: load.files, watchedFiles: load.watchedFiles, clashes: load.clashes)
    }

    /// Reads the config files again (⌘⇧, or a file change). A config with errors keeps the last good one.
    public func reloadConfig() {
        let load = loadConfigFiles()
        let (outcome, release) = configs.offer(load.config, errors: load.errors)
        if configs.current == load.config { ghostty_app_update_config(app, load.config) }
        if let release { ghostty_config_free(release) }
        lastConfigLoad = finishLoad(load, outcome: outcome)
        if source.watch { configWatch.watch(lastConfigLoad.watchedFiles) }
        onConfigLoad?(lastConfigLoad)
    }

    /// libghostty's `reload_config` action. A soft reload (a dark or light switch) applies the
    /// config in use again, so libghostty can pick the other theme. A hard one reads the files.
    func reloadConfig(target: ghostty_target_s, soft: Bool) {
        guard soft else { return reloadConfig() }
        guard let current = configs.current else { return }
        if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
            ghostty_surface_update_config(surface, current)
        } else {
            ghostty_app_update_config(app, current)
        }
    }

    /// libghostty's `config_change` action: it applied a config. Keep a copy for the window.
    func configChanged(target: ghostty_target_s, config: ghostty_config_t?) {
        guard target.tag == GHOSTTY_TARGET_APP, let config, let clone = ghostty_config_clone(config) else { return }
        if let old = appliedConfig { ghostty_config_free(old) }
        appliedConfig = clone
        onConfigChange?()
    }

    /// Sends the dark or light appearance to libghostty and to each pane.
    func setColorScheme(dark: Bool) {
        let scheme = dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_app_set_color_scheme(app, scheme)
        for view in TerminalSurfaceView.liveViews {
            if let surface = view.surface { ghostty_surface_set_color_scheme(surface, scheme) }
        }
    }

    // MARK: Window appearance

    /// The appearance options of the config that libghostty applied last.
    public var windowAppearance: WindowAppearance {
        let config = appliedConfig ?? configs.current
        var color = ghostty_config_color_s()
        let hasBackground = Self.get(config, "background", &color)
        let background = hasBackground
            ? NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
            : NSColor.windowBackgroundColor
        var opacity: Double = 1
        _ = Self.get(config, "background-opacity", &opacity)
        var blur: Int16 = 0
        _ = Self.get(config, "background-blur", &blur)
        return WindowAppearance(
            background: background, opacity: opacity, blur: blur,
            titlebarStyle: Self.string(config, "macos-titlebar-style") ?? "transparent",
            windowTheme: Self.string(config, "window-theme") ?? "auto",
            terminalBackground: hasBackground ? UInt32(color.r) << 16 | UInt32(color.g) << 8 | UInt32(color.b) : nil)
    }

    /// Applies the appearance options to a window: opacity, blur, titlebar style, and window
    /// theme. libghostty applies the colorspace itself, in each pane. Call it when the window
    /// shows and on each `onConfigChange`: blur has no effect on a window that is not visible.
    public func applyWindowAppearance(to window: NSWindow) {
        let options = windowAppearance
        switch options.windowTheme {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "auto":
            // The chrome palette uses the same rule (`ChromeSurfaces.isDark`).
            let dark = LoamTheme.hex(options.background).map(ChromeSurfaces.isDark) ?? true
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        default: window.appearance = nil
        }

        // Loam keeps the title bar: the sidebar and panel buttons sit in it. "tabs" and "hidden"
        // look like "transparent". A window with a toolbar shows the plot name as its title
        // (ticket 68). A window with none keeps the title hidden for every style.
        window.titlebarAppearsTransparent = options.titlebarStyle != "native"
        window.titleVisibility = window.toolbar == nil ? .hidden : .visible

        // `background-opacity` below 1 makes the window translucent, as in Ghostty. The panes draw
        // their own translucent background, and the app clears every ground behind them. The rule
        // is the same as `ChromePalette.isTranslucent`, so a glass `background-blur` at opacity 1
        // stays solid.
        if options.opacity < 1 {
            window.isOpaque = false
            // As Ghostty: nearly clear, not clear, which looks like Terminal.app.
            window.backgroundColor = .white.withAlphaComponent(0.001)
        } else {
            window.isOpaque = true
            window.backgroundColor = options.background
        }
        // Also when solid, so a blur from a translucent config goes when the config changes.
        if window.isVisible { ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque()) }
    }

    private static func get<T>(_ config: ghostty_config_t?, _ key: String, _ value: inout T) -> Bool {
        guard let config else { return false }
        return ghostty_config_get(config, &value, key, UInt(key.utf8.count))
    }

    private static func string(_ config: ghostty_config_t?, _ key: String) -> String? {
        var pointer: UnsafePointer<CChar>?
        guard get(config, key, &pointer), let pointer else { return nil }
        return String(cString: pointer)
    }

    // MARK: Opening the config

    /// The config file that ⌘, opens. For the default search, libghostty picks the file and
    /// makes an empty one if none exists, as Ghostty.app does.
    public var configFileToOpen: String? {
        if let user = source.user { return user.first }
        let string = ghostty_config_open_path()
        defer { ghostty_string_free(string) }
        guard let pointer = string.ptr, string.len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(string.len)), as: UTF8.self)
    }

    /// True when ⌘, has a file to open. It makes no file.
    public var canOpenConfig: Bool { source.user.map { !$0.isEmpty } ?? true }

    /// ⌘,: opens your Ghostty config in your text editor.
    public func openConfigFile() {
        guard let path = configFileToOpen else { return }
        let url = URL(fileURLWithPath: path)
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Keys

    /// The key that your config binds to a Ghostty action, such as "new_tab", for its menu item.
    public func chord(forGhosttyAction action: String) -> KeyChord? {
        guard let config = configs.current else { return nil }
        return KeyChord(ghostty: ghostty_config_trigger(config, action, UInt(action.utf8.count)))
    }
}

extension KeyChord {
    /// A Ghostty trigger, if a menu can show it.
    init?(ghostty trigger: ghostty_input_trigger_s) {
        let key: String
        switch trigger.tag {
        case GHOSTTY_TRIGGER_UNICODE:
            guard trigger.key.unicode > 0, let scalar = UnicodeScalar(trigger.key.unicode) else { return nil }
            key = String(Character(scalar))
        case GHOSTTY_TRIGGER_PHYSICAL:
            guard let name = Self.physicalNames[trigger.key.physical.rawValue] else { return nil }
            key = name
        default:
            return nil
        }
        var mods: Mods = []
        let raw = trigger.mods.rawValue
        if raw & GHOSTTY_MODS_SUPER.rawValue != 0 { mods.insert(.command) }
        if raw & GHOSTTY_MODS_SHIFT.rawValue != 0 { mods.insert(.shift) }
        if raw & GHOSTTY_MODS_ALT.rawValue != 0 { mods.insert(.option) }
        if raw & GHOSTTY_MODS_CTRL.rawValue != 0 { mods.insert(.control) }
        self.init(mods, key)
    }

    /// The physical keys a menu can show, as the character a US layout types.
    private static let physicalNames: [UInt32: String] = {
        var names: [UInt32: String] = [
            GHOSTTY_KEY_BACKQUOTE.rawValue: "`",
            GHOSTTY_KEY_BRACKET_LEFT.rawValue: "[",
            GHOSTTY_KEY_BRACKET_RIGHT.rawValue: "]",
            GHOSTTY_KEY_COMMA.rawValue: ",",
            GHOSTTY_KEY_EQUAL.rawValue: "=",
            GHOSTTY_KEY_MINUS.rawValue: "-",
            GHOSTTY_KEY_ARROW_UP.rawValue: "arrow_up",
            GHOSTTY_KEY_ARROW_DOWN.rawValue: "arrow_down",
            GHOSTTY_KEY_ARROW_LEFT.rawValue: "arrow_left",
            GHOSTTY_KEY_ARROW_RIGHT.rawValue: "arrow_right",
        ]
        for n in 0...9 { names[GHOSTTY_KEY_DIGIT_0.rawValue + UInt32(n)] = "\(n)" }
        for (i, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() { names[GHOSTTY_KEY_A.rawValue + UInt32(i)] = String(letter) }
        return names
    }()

    /// The chord of a key event: its modifiers and the character the key types with no modifier.
    public init?(event: NSEvent) {
        guard let characters = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
              let first = characters.first else { return nil }
        var mods: Mods = []
        let flags = event.modifierFlags
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        self.init(mods, String(first))
    }
}
