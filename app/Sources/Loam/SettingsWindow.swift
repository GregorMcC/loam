import AppKit
import LoamKit
import SwiftUI

/// The settings window on ⌘, (ticket 81, ADR 0006). It is a native macOS settings window:
/// toolbar tabs, and a grouped form in each tab. It uses system colours, not the chrome palette.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let windowID = NSUserInterfaceItemIdentifier("dev.loam.settings")
    private static let tabKey = "SettingsTab"

    private let settings: SettingsModel

    init(settings: SettingsModel, terminal: TerminalConfigModel) {
        self.settings = settings
        let tabs = RememberingTabViewController(key: Self.tabKey)
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.tab("General", symbol: "gearshape", GeneralSettingsView(model: settings)))
        tabs.addTabViewItem(Self.tab("Terminal", symbol: "terminal", TerminalSettingsView(model: terminal)))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.identifier = Self.windowID
        window.isReleasedWhenClosed = false
        super.init(window: window)
        tabs.selectSavedTab()
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func tab(_ label: String, symbol: String, _ view: some View) -> NSTabViewItem {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        // The tab view controller gives the window the selected tab's title.
        host.title = label
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.identifier = label
        return item
    }

    /// Shows the window, or brings it to the front. Each show checks the `loam` binary again.
    func show() {
        settings.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        Task { await settings.checkLoam() }
    }
}

/// A tab view controller that opens on the tab you used last.
private final class RememberingTabViewController: NSTabViewController {
    private let key: String

    init(key: String) {
        self.key = key
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func selectSavedTab() {
        let saved = UserDefaults.standard.integer(forKey: key)
        if tabViewItems.indices.contains(saved) { selectedTabViewItemIndex = saved }
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        UserDefaults.standard.set(selectedTabViewItemIndex, forKey: key)
    }
}

// MARK: General

struct GeneralSettingsView: View {
    let model: SettingsModel
    @State private var customPath = ""

    var body: some View {
        Form {
            if let error = model.fileError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings-file-error")
                }
            }
            repoFolders
            loamBinary
            Section {
                LabeledContent("Settings file") {
                    HStack {
                        Text(model.display(model.file.url.path))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Open") { openSettingsFile() }
                            .accessibilityIdentifier("settings-open-file")
                    }
                }
            } footer: {
                Text("You can also edit the file by hand. Loam applies a change at once.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.settings.loamPath, initial: true) { _, path in
            customPath = path ?? ""
        }
        .task(id: model.loam.path) { await model.checkLoam() }
    }

    private var repoFolders: some View {
        Section {
            if model.settings.repoFolders.isEmpty {
                Text("No folders. The add repo row offers only the folders of repos you already added.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.settings.repoFolders, id: \.self) { folder in
                HStack {
                    Label(folder, systemImage: "folder")
                    Spacer()
                    if !FileManager.default.fileExists(atPath: SettingsPath.expand(folder, home: NSHomeDirectory())) {
                        Text("Missing").foregroundStyle(.orange)
                    }
                    Button {
                        model.removeRepoFolders([folder])
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(folder)")
                    .accessibilityLabel("Remove \(folder)")
                }
                .contextMenu { Button("Remove") { model.removeRepoFolders([folder]) } }
            }
            Button("Add Folder\u{2026}", systemImage: "plus") { chooseFolder() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("settings-add-folder")
        } header: {
            Text("Repo folders")
        } footer: {
            Text("When you add a repo to a plot, Loam suggests the git checkouts in these folders.")
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("settings-repo-folders")
    }

    private var loamBinary: some View {
        Section {
            Picker("Location", selection: automatic) {
                Text("Automatic").tag(true)
                Text("Custom").tag(false)
            }
            .accessibilityIdentifier("settings-loam-mode")
            if model.settings.loamPath != nil {
                LabeledContent("Path") {
                    HStack {
                        TextField("Path", text: $customPath, prompt: Text("/path/to/loam"))
                            .labelsHidden()
                            .onSubmit { model.setLoamPath(customPath) }
                            .accessibilityIdentifier("settings-loam-path")
                        Button("Choose\u{2026}") { chooseBinary() }
                    }
                }
            } else {
                LabeledContent("Path") {
                    Text(model.display(model.loam.path))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Status") { status }
            if model.needsRestart {
                Label("Loam uses this binary after you restart it.", systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-restart-note")
            }
        } header: {
            Text("The loam command")
        } footer: {
            Text("Automatic looks in ~/.local/bin, then Homebrew, then in Loam.app, then your PATH.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        switch model.loamStatus {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking\u{2026}").foregroundStyle(.secondary)
            }
        case .ok(let version, let contract):
            Label("loam \(version), contract \(contract)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("settings-loam-ok")
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .accessibilityIdentifier("settings-loam-failed")
        }
    }

    /// Automatic or Custom. Custom starts from the path that Automatic found, so nothing breaks.
    private var automatic: Binding<Bool> {
        Binding(
            get: { model.settings.loamPath == nil },
            set: { automatic in model.setLoamPath(automatic ? nil : model.loam.path) }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        present(panel) { urls in urls.forEach { model.addRepoFolder($0.path) } }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        let current = SettingsPath.expand(customPath, home: NSHomeDirectory())
        panel.directoryURL = URL(fileURLWithPath: (current as NSString).deletingLastPathComponent)
        present(panel) { urls in if let url = urls.first { model.setLoamPath(url.path) } }
    }

    private func present(_ panel: NSOpenPanel, chosen: @escaping ([URL]) -> Void) {
        let done: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { chosen(panel.urls) }
        }
        if let window = NSApp.windows.first(where: { $0.identifier == SettingsWindowController.windowID }) {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(panel.runModal())
        }
    }

    /// Opens the file in your text editor. A missing file is written with the defaults first.
    private func openSettingsFile() {
        let url = model.file.url
        if !FileManager.default.fileExists(atPath: url.path) { try? model.file.write(model.settings) }
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: Terminal

struct TerminalSettingsView: View {
    let model: TerminalConfigModel

    var body: some View {
        Form {
            Section {
                if model.files.isEmpty {
                    Text("You have no Ghostty config file. Loam uses Ghostty's defaults.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.files, id: \.self) { file in
                    Label(SettingsPath.abbreviate(file, home: NSHomeDirectory()), systemImage: "doc.text")
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Open Config") { model.open() }
                        .disabled(!model.canOpen)
                        .accessibilityIdentifier("settings-open-ghostty")
                    Button("Reload") { model.reload() }
                        .accessibilityIdentifier("settings-reload-ghostty")
                    Spacer()
                }
            } header: {
                Text("Ghostty config")
            } footer: {
                Text("The font, the theme, and the keys come from your Ghostty config. Loam reloads it when a file changes. \u{21E7}\u{2318}, also reloads it.")
                    .foregroundStyle(.secondary)
            }
            if !model.errors.isEmpty {
                Section {
                    ForEach(model.errors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text(model.errors.count == 1 ? "1 error" : "\(model.errors.count) errors")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}
