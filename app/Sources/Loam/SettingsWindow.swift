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

    init(settings: SettingsModel, terminal: TerminalConfigModel, connections: ConnectionsModel,
         runs: RunsSettingsModel) {
        self.settings = settings
        let tabs = RememberingTabViewController(key: Self.tabKey)
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.tab("General", symbol: "gearshape", GeneralSettingsView(model: settings)))
        tabs.addTabViewItem(Self.tab("Terminal", symbol: "terminal", TerminalSettingsView(model: terminal)))
        tabs.addTabViewItem(Self.tab("Runs", symbol: "checklist", RunsSettingsView(model: runs)))
        tabs.addTabViewItem(Self.tab("Connections", symbol: "link", ConnectionsSettingsView(model: connections)))
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

// MARK: Grouped rows

/// A titled group of rows in a rounded well, with a caption under it (the Connections and Runs tabs).
private struct SettingsGroup<Content: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LoamColor.ink).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .background(LoamColor.inkFill, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LoamColor.inkHairline))
            if let caption {
                Text(caption).loamText(LoamTheme.captionStyle, LoamColor.inkMuted).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One row of a group: a label on the left, the value on the right, and a hairline above it unless it is first.
private struct SettingsRow<Value: View>: View {
    let label: String
    var first = false
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first { Rectangle().fill(LoamColor.inkHairline).frame(height: 1) }
            HStack(spacing: 12) {
                Text(label).loamText(LoamTheme.bodyStyle, LoamColor.inkMuted).frame(width: 120, alignment: .leading)
                value.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
    }
}

// MARK: Connections

/// The Linear key, what each plot reads, and the updates to Linear (tickets 205 and the Linear sweep). The field is
/// empty after a save, and a stored key shows as a mask: the app never reads the key back.
struct ConnectionsSettingsView: View {
    let model: ConnectionsModel
    @State private var key = ""
    @State private var replacing = false
    @State private var confirmingDisconnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                linear
                plots
                updates
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(LoamColor.needsYou)
                        .accessibilityIdentifier("settings-linear-error")
                }
            }
            .padding(20)
        }
        .frame(width: 640, height: 640)
        .task { await model.load() }
    }

    private var hasKey: Bool { model.linear?.connected == true }

    private var linear: some View {
        SettingsGroup(
            title: "Linear",
            caption: "Loam keeps the key in your macOS Keychain, and only the Loam core reads it. Seeded sessions never see it."
        ) {
            SettingsRow(label: "Account", first: true) {
                HStack {
                    Text(model.accountWords ?? model.linearWords).loamText(LoamTheme.bodyStyle)
                        .accessibilityIdentifier("settings-linear-status")
                    Spacer()
                    if hasKey { disconnect }
                }
            }
            SettingsRow(label: "API key") {
                if hasKey && !replacing { maskRow } else { keyField }
            }
        }
    }

    @ViewBuilder private var disconnect: some View {
        if confirmingDisconnect {
            Text("Remove the key?").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            Button("Cancel") { confirmingDisconnect = false }
                .accessibilityIdentifier("settings-linear-remove-cancel")
            Button("Disconnect") {
                confirmingDisconnect = false
                Task { await model.removeLinearKey() }
            }
            .tint(LoamColor.rust)
            .disabled(model.isWorking)
            .accessibilityIdentifier("settings-linear-remove")
        } else {
            Button("Disconnect") { confirmingDisconnect = true }
                .accessibilityIdentifier("settings-linear-disconnect")
        }
    }

    private var maskRow: some View {
        HStack {
            Text(ConnectionsModel.keyMask)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(LoamColor.inkMuted)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LoamColor.inkFill, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("settings-linear-mask")
            Button("Replace\u{2026}") { replacing = true }
                .accessibilityIdentifier("settings-linear-replace")
        }
    }

    private var keyField: some View {
        HStack {
            SecureField("lin_api_...", text: $key)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
                .accessibilityIdentifier("settings-linear-key")
            Button("Save") { save() }
                .loamPrimaryButton()
                .disabled(model.isWorking || key.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("settings-linear-save")
            if replacing {
                Button("Cancel") {
                    key = ""
                    replacing = false
                }
                .accessibilityIdentifier("settings-linear-cancel")
            }
        }
    }

    private var plots: some View {
        SettingsGroup(
            title: "What each plot reads",
            caption: "A plot's Linear link sets what its Intake shows. To change the scope, edit the link in the plot panel."
        ) {
            HStack(spacing: 12) {
                Text("Plot").frame(width: 150, alignment: .leading)
                Text("Linear scope").frame(maxWidth: .infinity, alignment: .leading)
                Text("From the link").frame(width: 170, alignment: .leading)
            }
            .loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
            .padding(.horizontal, 14).padding(.vertical, 8)
            ForEach(model.scopeRows) { row in
                Rectangle().fill(LoamColor.inkHairline).frame(height: 1)
                HStack(spacing: 12) {
                    Text(row.plot).loamText(LoamTheme.bodyStyle).frame(width: 150, alignment: .leading)
                    Text(row.scope).loamText(LoamTheme.bodyStyle, row.hasScope ? LoamColor.ink : LoamColor.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.source).loamText(LoamTheme.bodyStyle, LoamColor.inkMuted).frame(width: 170, alignment: .leading)
                }
                .lineLimit(2)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings-scope-\(row.id)")
            }
        }
    }

    private var updates: some View {
        SettingsGroup(
            title: "Updates to Linear",
            caption: "Loam writes to Linear only on these events. Each write is an event of the run, with its result. A failed write never stops a run."
        ) {
            toggle("When a run starts, move the issue to In Progress", \.inProgress, id: "in-progress", first: true)
            toggle("When the PR opens, attach it to the issue", \.attachPR, id: "attach-pr")
            toggle("When you land a run, move the issue to Done", \.done, id: "done")
            toggle("When you land a run, add its walkthrough as a comment", \.walkthroughComment, id: "walkthrough")
            Text("Landed in #<PR> by a Loam run. <The walkthrough that Claude wrote at Ship.> <n> of <n> checks passed.")
                .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LoamColor.inkFill, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 14).padding(.bottom, 12)
        }
    }

    private func toggle(_ label: String, _ keyPath: WritableKeyPath<LinearUpdates, Bool>, id: String,
                        first: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first { Rectangle().fill(LoamColor.inkHairline).frame(height: 1) }
            Toggle(label, isOn: Binding(
                get: { model.updates?[keyPath: keyPath] ?? false },
                set: { on in Task { await model.setUpdate(keyPath, on) } }))
                .toggleStyle(.checkbox)
                .disabled(model.updates == nil)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .accessibilityIdentifier("settings-update-\(id)")
        }
    }

    private func save() {
        let text = key
        Task {
            if await model.setLinearKey(text) {
                key = ""
                replacing = false
            }
        }
    }
}

// MARK: Runs

/// The limits of every run, and the usage that the hold reads. Each field saves when you press Return or leave it.
struct RunsSettingsView: View {
    let model: RunsSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(
                    title: "Limits",
                    caption: "A run that cannot start waits for a slot, and starts when one frees."
                ) {
                    limit("At a time", id: "at-a-time", range: 1...20, value: model.limits?.atATime, first: true) {
                        await model.setAtATime($0)
                    }
                    limit("Turn limit", id: "max-turns", range: 0...1000, value: model.limits?.maxTurns,
                          note: "Each run's turn limit. 0 is no limit.") { await model.setMaxTurns($0) }
                    limit("Hold at", id: "hold-at", range: 0...100, value: model.limits?.holdAt,
                          note: "Hold new runs at this percent of the week's usage. 0 is off.") { await model.setHoldAt($0) }
                }
                SettingsGroup(title: "Usage", caption: "Loam reads the usage again when a reading is older than 30 minutes.") {
                    SettingsRow(label: "Usage this week", first: true) {
                        Text(model.usageWords ?? "No reading yet").loamText(LoamTheme.bodyStyle)
                            .accessibilityIdentifier("settings-runs-usage")
                    }
                }
                SettingsGroup(
                    title: "Sandbox",
                    caption: "A run works in a sandbox. Add toolchain folders and hosts for every plot here. "
                        + "A plot can add more in its run defaults. Loam refuses a path that opens your home folder. A change holds for the next new session of a run."
                ) {
                    SandboxListsView(model: model.sandbox, scope: "machine").padding(14)
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(LoamColor.needsYou)
                        .accessibilityIdentifier("settings-runs-error")
                }
            }
            .padding(20)
        }
        .frame(width: 640, height: 640)
        .task { await model.load() }
    }

    private func limit(_ label: String, id: String, range: ClosedRange<Int>, value: Int?, note: String? = nil,
                       first: Bool = false, save: @escaping (Int) async -> Void) -> some View {
        SettingsRow(label: label, first: first) {
            HStack {
                LimitField(id: id, range: range, value: value, save: save)
                if let note { Text(note).loamText(LoamTheme.captionStyle, LoamColor.inkMuted) }
            }
        }
    }
}

/// A number field with a stepper. It shows the saved value and saves a new one on Return, on a step, or when it loses focus.
private struct LimitField: View {
    let id: String
    let range: ClosedRange<Int>
    let value: Int?
    let save: (Int) async -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, now in if !now { commit() } }
                .accessibilityIdentifier("settings-runs-\(id)")
            Stepper("", value: Binding(get: { value ?? range.lowerBound }, set: { new in Task { await save(new) } }), in: range)
                .labelsHidden()
        }
        .disabled(value == nil)
        .onChange(of: value, initial: true) { _, new in if let new { text = String(new) } }
    }

    private func commit() {
        guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else {
            text = value.map(String.init) ?? ""
            return
        }
        let clamped = min(max(number, range.lowerBound), range.upperBound)
        text = String(clamped)
        Task { await save(clamped) }
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
                        // A path has no spaces, so it would wrap at a hyphen and leave the lines uneven. It keeps one line and
                        // cuts in the middle, and the tooltip holds all of it (TAS-35).
                        Text(model.display(model.file.url.path))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.display(model.file.url.path))
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
                    // One line, cut in the middle, as the path of the settings file.
                    Label(folder, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder)
                        .layoutPriority(1)
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
