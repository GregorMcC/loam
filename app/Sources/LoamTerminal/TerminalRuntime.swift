// The clipboard callbacks in this file are ported from Ghostty's macOS host
// layer (macos/Sources/Ghostty/Ghostty.App.swift) at the commit in ghostty.pin.
//
// MIT License
//
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import AppKit
import GhosttyKit
import LoamKit

/// Owns the app's one `ghostty_app_t`. Every pane is a surface inside it.
@MainActor
public final class TerminalRuntime {
    /// Where the runtime reads the Ghostty config (spec 8.3).
    public struct ConfigSource: Sendable {
        /// Loam's own default files. They load first, so your config overrides each value.
        /// The app lists the Loam theme file here (`TerminalThemeDefaults`).
        public var defaults: [String]
        /// Your Ghostty config files. Nil is Ghostty's default search.
        public var user: [String]?
        /// Watch the files with FSEvents and reload on a change.
        public var watch: Bool

        public init(defaults: [String] = [], user: [String]? = nil, watch: Bool = true) {
            self.defaults = defaults
            self.user = user
            self.watch = watch
        }

        /// Your Ghostty config files, the same search as Ghostty.app, watched.
        public static let defaultFiles = ConfigSource()
        /// One config file only. The driver uses this, so tests do not depend on your config.
        public static func file(_ path: String, watch: Bool = false) -> ConfigSource {
            ConfigSource(user: [path], watch: watch)
        }
        /// libghostty's defaults only.
        public static let none = ConfigSource(user: [], watch: false)
    }

    public private(set) var app: ghostty_app_t!
    let source: ConfigSource
    /// The config in use: the last load with no errors (or the first load).
    var configs = LastGoodConfig<ghostty_config_t>()
    /// The config that libghostty applied last, with the dark or light theme chosen. The
    /// window appearance reads it. Nil until the first `config_change` action.
    var appliedConfig: ghostty_config_t?
    let configWatch = ConfigWatch()

    /// The config errors from the last load.
    public var configDiagnostics: [String] { configs.errors }
    /// What the last config load did. The app shows the errors and logs the clashes.
    public internal(set) var lastConfigLoad: ConfigLoad!
    /// Called after each config load, after launch.
    public var onConfigLoad: ((ConfigLoad) -> Void)?
    /// Called when libghostty applies a config: a load, or a dark or light switch. The window
    /// applies its appearance options again.
    public var onConfigChange: (() -> Void)?
    /// Runs a Loam command: a fixed Loam key in a pane, or a Ghostty action that Loam handles.
    /// Return true when the command did something. For a performable Ghostty binding, such as
    /// ⌘Z, false sends the key on to the terminal.
    public var commandHandler: ((AppCommand) -> Bool)?
    private var appearanceObservation: NSKeyValueObservation?

    /// The pasteboard for copy and paste. The driver uses a private one, so
    /// tests never touch your clipboard.
    public var pasteboard: NSPasteboard = .general
    /// The pasteboard for the selection clipboard (copy on select).
    public var selectionPasteboard = NSPasteboard(name: .init("dev.loam.selection"))
    /// True when each pane acts as if its window is key and visible. The driver sets it, so a run
    /// behind your other windows still draws and takes focus without the app coming to the front.
    public var assumesKeyAndVisible = false

    /// A hook for actions that the runtime does not handle itself, such as
    /// the tab and split actions. Return true when the hook handled it.
    public var actionHandler: ((ghostty_target_s, ghostty_action_s) -> Bool)?

    /// The count of each action tag that libghostty sent. The driver logs it.
    public private(set) var actionCounts: [UInt32: Int] = [:]

    private var observers: [NSObjectProtocol] = []

    /// Removes the leaked variables from the process environment, then starts
    /// libghostty. Call it once, before any runtime. libghostty copies the
    /// environment here, and every pane starts from that copy (spec 8.2).
    ///
    /// `resources` is the Ghostty resources folder (themes, shell integration, and terminfo
    /// next to it). It replaces any inherited `GHOSTTY_RESOURCES_DIR`, and libghostty reads it
    /// here. Do not change the environment after this call: libghostty keeps the process's
    /// `environ` array, not a copy, and a removed variable leaves a null slot in it.
    ///
    /// libghostty adds `GHOSTTY_RESOURCES_DIR` to each pane itself (`termio/Exec.zig`), and
    /// at the pinned commit no surface or config setting removes it (an empty `env` value only
    /// drops the key from the config map). So a pane gets Loam's own value, never an inherited
    /// one. `LoamClient` removes the variable from `loam` subprocesses.
    public static func bootstrap(resources: String? = nil) -> Bool {
        for key in PaneEnvironment.keysToRemove(from: ProcessInfo.processInfo.environment) {
            unsetenv(key)
        }
        if let resources { setenv(resourcesVariable, resources, 1) }
        return ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS
    }

    public static let resourcesVariable = "GHOSTTY_RESOURCES_DIR"

    /// The Ghostty resources folder: `Contents/Resources/ghostty` in the app bundle, else the
    /// `ghostty-share` link that `scripts/build-ghosttykit.sh` makes in `app/vendor`. Nil when
    /// neither exists.
    public static func resourcesFolder(bundle: Bundle = .main) -> String? {
        let manager = FileManager.default
        let sourceFile = #filePath
        if let bundled = bundle.resourceURL?.appendingPathComponent("ghostty").path,
           manager.fileExists(atPath: bundled + "/themes") {
            return bundled
        }
        // app/Sources/LoamTerminal/TerminalRuntime.swift -> app/vendor/ghostty-share/ghostty
        let app = URL(fileURLWithPath: sourceFile).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let vendored = app.appendingPathComponent("vendor/ghostty-share/ghostty").path
        return manager.fileExists(atPath: vendored + "/themes") ? vendored : nil
    }

    /// Make one runtime and keep it for the life of the app. libghostty holds
    /// a pointer to it in every callback, and the app is never freed.
    public init(config source: ConfigSource = .defaultFiles) {
        self.source = source
        let load = loadConfigFiles()
        let (outcome, _) = configs.offer(load.config, errors: load.errors)
        lastConfigLoad = finishLoad(load, outcome: outcome)

        var runtime = Self.runtimeConfig(userdata: Unmanaged.passUnretained(self).toOpaque())
        app = ghostty_app_new(&runtime, configs.current)
        precondition(app != nil, "ghostty_app_new failed")

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self.map { ghostty_app_set_focus($0.app, true) } } })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self.map { ghostty_app_set_focus($0.app, false) } } })
        observers.append(center.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self.map { ghostty_app_keyboard_changed($0.app) } } })
        ghostty_app_set_focus(app, NSApp?.isActive ?? false)

        // The dark or light appearance (spec 8.3). A `theme = dark:…,light:…` follows it.
        if let application = NSApp {
            appearanceObservation = application.observe(\.effectiveAppearance, options: [.new, .initial]) { [weak self] app, _ in
                let dark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                MainActor.assumeIsolated { self?.setColorScheme(dark: dark) }
            }
        }
        configWatch.onChange = { [weak self] in self?.reloadConfig() }
        if source.watch { configWatch.watch(lastConfigLoad.watchedFiles) }
    }

    /// The C callbacks. Nonisolated: libghostty calls some of them on its own threads.
    nonisolated private static func runtimeConfig(userdata: UnsafeMutableRawPointer) -> ghostty_runtime_config_s {
        return ghostty_runtime_config_s(
            userdata: userdata,
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in
                // Any thread. Tick on the main thread.
                let address = UInt(bitPattern: userdata)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
                        Unmanaged<TerminalRuntime>.fromOpaque(pointer).takeUnretainedValue().tick()
                    }
                }
            },
            action_cb: { app, target, action in
                guard let app, let userdata = ghostty_app_userdata(app) else { return false }
                // The renderer thread sends some actions, such as renderer
                // health. Their payload pointers live only for this call, and
                // Loam needs none of them, so count them and go on.
                guard Thread.isMainThread else {
                    let address = UInt(bitPattern: userdata)
                    let tag = action.tag.rawValue
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
                            Unmanaged<TerminalRuntime>.fromOpaque(pointer).takeUnretainedValue().actionCounts[tag, default: 0] += 1
                        }
                    }
                    return false
                }
                nonisolated(unsafe) let runtimeData = userdata
                return MainActor.assumeIsolated {
                    Unmanaged<TerminalRuntime>.fromOpaque(runtimeData).takeUnretainedValue()
                        .handle(target: target, action: action)
                }
            },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, list in
                // libghostty calls the clipboard callbacks on the main thread.
                nonisolated(unsafe) let (userdata, state, mimes) = (userdata, state, mimes)
                return MainActor.assumeIsolated {
                    guard let view = TerminalSurfaceView.from(userdata) else {
                        return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
                    }
                    return view.runtime.readClipboard(
                        view, location: location, state: state, mimes: mimes, mimesLen: mimesLen, list: list)
                }
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                nonisolated(unsafe) let (userdata, confirm, state) = (userdata, confirm, state)
                MainActor.assumeIsolated {
                    guard let view = TerminalSurfaceView.from(userdata) else { return }
                    view.runtime.confirmReadClipboard(view, confirm: confirm, state: state, request: request)
                }
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                nonisolated(unsafe) let (userdata, content) = (userdata, content)
                MainActor.assumeIsolated {
                    guard let view = TerminalSurfaceView.from(userdata) else { return }
                    view.runtime.writeClipboard(view, location: location, content: content, len: len, confirm: confirm)
                }
            },
            close_surface_cb: { userdata, processAlive in
                // Do not close inside libghostty's call. Defer to the run loop.
                let address = UInt(bitPattern: userdata)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let view = TerminalSurfaceView.from(UnsafeMutableRawPointer(bitPattern: address)) else { return }
                        view.libghosttyRequestedClose(processAlive: processAlive)
                    }
                }
            }
        )
    }

    public func tick() {
        ghostty_app_tick(app)
    }

    // MARK: Actions

    private func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        actionCounts[action.tag.rawValue, default: 0] += 1
        switch action.tag {
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            reloadConfig(target: target, soft: action.action.reload_config.soft)
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            configChanged(target: target, config: action.action.config_change.config)
            return true
        default:
            break
        }
        if let actionHandler, actionHandler(target, action) { return true }
        if let command = AppCommand(ghostty: action) {
            return commandHandler?(command) ?? false
        }

        var view: TerminalSurfaceView?
        if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
            view = TerminalSurfaceView.from(ghostty_surface_userdata(surface))
        }
        guard let view else { return false }

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            view.title = action.action.set_title.title.map { String(cString: $0) } ?? ""
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            view.onChildExited?(Int32(bitPattern: action.action.child_exited.exit_code))
            // False keeps libghostty's own "process exited" message in the pane.
            return view.replacesExitMessage
        case GHOSTTY_ACTION_RING_BELL:
            view.onBell?()
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let note = action.action.desktop_notification
            view.onDesktopNotification?(
                note.title.map { String(cString: $0) } ?? "",
                note.body.map { String(cString: $0) } ?? "")
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let size = action.action.cell_size
            view.cellSizeInPixels = NSSize(width: Double(size.width), height: Double(size.height))
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view.setCursorShape(action.action.mouse_shape)
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
            return true
        default:
            return false
        }
    }

    // MARK: Clipboard

    func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: pasteboard
        case GHOSTTY_CLIPBOARD_SELECTION: selectionPasteboard
        default: nil // macOS has no primary selection.
        }
    }

    fileprivate func readClipboard(
        _ view: TerminalSurfaceView,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let surface = view.surface, let pasteboard = pasteboard(for: location) else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }
        // Read only the requested types, so large unrelated contents stay unread.
        var contents: [ClipboardContent] = []
        var seen = Set<String>()
        if let mimes {
            for i in 0..<mimesLen {
                guard let pointer = mimes[i] else { continue }
                let mime = String(cString: pointer)
                guard seen.insert(mime).inserted, let data = pasteboard.loamData(forMime: mime) else { continue }
                contents.append(ClipboardContent(mime: mime, data: data))
            }
        }
        let available = list ? pasteboard.loamAvailableMimes() : []
        if contents.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        ClipboardContent.complete(surface, contents: contents, available: available, state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    fileprivate func confirmReadClipboard(
        _ view: TerminalSurfaceView,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let surface = view.surface else { return }
        guard let confirm, let kind = ClipboardConfirmation.Kind(request) else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }
        let c = confirm.pointee
        // Copy the borrowed C data. The answer comes later, and it must paste
        // exactly what the prompt showed.
        var contents: [ClipboardContent] = []
        if let items = c.contents {
            contents = (0..<c.contents_len).compactMap { ClipboardContent(items[$0]) }
        }
        var available: [String] = []
        if let mimes = c.available {
            for i in 0..<c.available_len {
                if let pointer = mimes[i] { available.append(String(cString: pointer)) }
            }
        }
        let preview = contents.first { $0.mime == "text/plain" }.flatMap { String(data: $0.data, encoding: .utf8) }
            ?? contents.map { "\($0.mime) (\($0.data.count) bytes)" }.joined(separator: "\n")

        view.present(ClipboardConfirmation(kind: kind, preview: preview) { [weak view] confirmed in
            guard let surface = view?.surface else { return }
            if confirmed {
                ClipboardContent.complete(surface, contents: contents, available: available, state: state, confirmed: true)
            } else {
                ghostty_surface_deny_clipboard_request(surface, state)
            }
        })
    }

    fileprivate func writeClipboard(
        _ view: TerminalSurfaceView,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let pasteboard = pasteboard(for: location), let content, len > 0 else { return }
        let items = (0..<len).compactMap { ClipboardContent(content[$0]) }
        guard !items.isEmpty else { return }

        if !confirm {
            pasteboard.declareTypes(items.compactMap { NSPasteboard.PasteboardType(mimeType: $0.mime) }, owner: nil)
            for item in items {
                if let type = NSPasteboard.PasteboardType(mimeType: item.mime) { pasteboard.setData(item.data, forType: type) }
            }
            return
        }

        // The prompt shows text only, so a confirmed write is the text only.
        guard let text = items.first(where: { $0.mime == "text/plain" }).flatMap({ String(data: $0.data, encoding: .utf8) })
        else { return }
        view.present(ClipboardConfirmation(kind: .osc52Write, preview: text) { confirmed in
            guard confirmed else { return }
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(text, forType: .string)
        })
    }
}
