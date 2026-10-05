import AppKit
import LoamKit
import SwiftUI

/// The plot panel (spec 8.6 and 8.7, tickets 72 and 87): the brief, repos, links, and changes of the
/// active plot, as a calm inspector. It is the sibling of the glass sidebar: plain sections with
/// sentence-case headings, property rows, a raised "Where it stands" card, and rows with a neutral
/// hover. It renders `PlotPanelModel` and `ReviewModel`. Every write goes through the models and
/// `loam`. The callouts (an error, a clash, a missing link, and the changes that are new since you
/// looked) stand at the top.
struct PlotPanelView: View {
    let model: PlotPanelModel
    let review: ReviewModel
    let app: AppModel

    /// The inline add row that is open. One at a time.
    @State private var adding: AddRow?
    @State private var newRepo = ""
    @State private var newLabel = ""
    @State private var newTarget = ""
    /// True while an add runs, so a second Return does not add the same item again.
    @State private var addBusy = false
    @State private var editingLink: String?
    @State private var linkLabel = ""
    @State private var linkTarget = ""
    @State private var linkNote = ""
    /// True while a drag over the panel holds something it can add.
    @State private var dropTargeted = false
    @FocusState private var focus: Field?
    /// The window of the panel, for the field editor of a brief field.
    @State private var window = WindowRef()

    enum AddRow { case repo, link }
    enum Field: Hashable { case newRepo, newTarget, linkLabel }

    var body: some View {
        Group {
            if let plot = model.plot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        callouts(plot)
                        properties(plot)
                        whereItStands
                        plainBrief(.what)
                        plainBrief(.why)
                        repos(plot)
                        links(plot)
                        ChangeLogSection(review: review, plot: plot.id)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                // Ticket 78: a drop adds a git checkout as a repo, and any other file, folder, or URL as a link.
                .dropDestination(for: URL.self) { urls, _ in
                    guard !urls.isEmpty else { return false }
                    Task { await model.addDropped(urls) }
                    return true
                } isTargeted: { dropTargeted = $0 }
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: LoamTheme.radiusMd)
                            .strokeBorder(LoamColor.moss, lineWidth: 2)
                            .padding(LoamTheme.space2)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                Text("No plot.").loamText(LoamTheme.emptyTitleStyle, LoamColor.inkMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(PanelGround().ignoresSafeArea())
        .background(WindowReader(ref: window))
        .animation(LoamAnimation.arrive, value: model.clash != nil)
        .animation(LoamAnimation.arrive, value: review.clash != nil)
        .onChange(of: model.plot?.id) { closeEditors() }
        // Add link and Add repo from the actions menu (ticket 89). They wait for the plot, because a
        // plot load closes the editors.
        .task(id: PanelRequestKey(request: model.readyRequest, plot: model.plot?.id)) {
            guard let request = model.readyRequest, request != .editBrief else { return }
            await Task.yield()
            model.request = nil
            open(request == .addLink ? .link : .repo)
        }
        .accessibilityIdentifier("plot-panel")
    }

    // MARK: Callouts

    @ViewBuilder private func callouts(_ plot: Plot) -> some View {
        if let message = model.errorMessage {
            CalloutCard(tone: .error) {
                PanelCallout(message).accessibilityIdentifier("panel-error")
            }
        }
        if let message = review.errorMessage {
            CalloutCard(tone: .error) {
                PanelCallout(message).accessibilityIdentifier("panel-review-error")
            }
        }
        if let message = model.notice {
            CalloutCard {
                PanelCallout(message).accessibilityIdentifier("panel-notice")
                TrailingButtons(pill: true) {
                    Button("OK") { model.notice = nil }
                }
            }
        }
        if let clash = model.clash { clashSection(clash) }
        if let prompt = review.clash { UndoClashSection(review: review, prompt: prompt) }
        if let missing = model.missingLink { missingSection(missing) }
        NewSinceSection(review: review, plot: plot.id)
    }

    private func clashSection(_ clash: EditClash) -> some View {
        CalloutCard {
            PanelCallout("\(clash.title) changed while you edited it.", emphasis: true)
                .accessibilityIdentifier("panel-clash")
            CalloutText(title: "Current", text: clash.current ?? "(removed)")
            CalloutText(title: "Yours", text: clash.yours)
            TrailingButtons(pill: true) {
                Button("Use current") { Task { await model.useCurrent() } }
                    .accessibilityIdentifier("panel-clash-use-current")
                Button("Keep mine") { Task { await model.keepMine() } }
                    .accessibilityIdentifier("panel-clash-keep-mine")
            }
        }
        .transition(LoamAnimation.growIn)
    }

    private func missingSection(_ missing: MissingLink) -> some View {
        CalloutCard {
            PanelCallout("The path does not exist: \(missing.path)", symbol: "questionmark.folder.fill")
                .accessibilityIdentifier("panel-missing-link")
            TrailingButtons(pill: true) {
                Button("Dismiss") { model.dismissMissingLink() }
                Button("Edit link") {
                    if let link = model.plot?.links.first(where: { $0.id == missing.linkID }) {
                        beginEditing(link)
                    }
                    model.dismissMissingLink()
                }
                .accessibilityIdentifier("panel-missing-edit-link")
            }
        }
    }

    // MARK: Properties

    /// The label and value rows at the top: the main repo with its branch, the panes, and the last change.
    @ViewBuilder private func properties(_ plot: Plot) -> some View {
        let mainRepo = plot.repos.first(where: \.main)
        let panes = app.workspace.paneIDs(of: plot.id)
        let needsYou = panes.filter { app.workspace.attention(of: $0) == .needsYou }.count
        let doneUnread = panes.filter { app.workspace.attention(of: $0) == .doneUnread }.count
        let last = review.log(plot: plot.id).first
        VStack(alignment: .leading, spacing: 0) {
            if let mainRepo {
                PropertyRow(label: "Main repo") {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LoamColor.inkMuted)
                    Text((mainRepo.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    if let branch = app.repoCheckouts[plot.id]?.first(where: \.isMain)?.branch {
                        Text(branch)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(LoamColor.inkMuted)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(LoamColor.chipFill, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .accessibilityIdentifier("panel-property-repo")
            }
            PropertyRow(label: "Panes") {
                Text(PanelProperties.paneSummary(panes: panes.count, needsYou: needsYou, doneUnread: doneUnread))
                    .lineLimit(1)
            }
            .accessibilityIdentifier("panel-property-panes")
            if let last {
                PropertyRow(label: "Updated") {
                    Text("\(ChangeRules.stamp(last.at, timeZone: review.timeZone)) \u{00B7} \(ChangeRules.actorName(last.actor))")
                        .lineLimit(1)
                }
                .accessibilityIdentifier("panel-property-updated")
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: Brief

    /// The raised card under the properties: "Where it stands", who set it and when, then the text.
    private var whereItStands: some View {
        let field = BriefField.whereItStands
        let last = model.plot.flatMap { plot in
            review.log(plot: plot.id).first { change in change.entries.contains { $0.item == field.itemKey } }
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.title).font(.system(size: 12, weight: .medium)).foregroundStyle(LoamColor.inkFaint)
                Spacer()
                if let last {
                    Text("\(ChangeRules.actorName(last.actor)) \u{00B7} \(ChangeRules.stamp(last.at, timeZone: review.timeZone))")
                        .font(.system(size: 11.5)).foregroundStyle(LoamColor.inkFaint)
                        .lineLimit(1)
                }
            }
            BriefText(model: model, window: window, field: field, size: 13.5, color: LoamColor.ink, inset: 0)
            briefButtons(field)
            if let warning = model.briefWarning {
                PanelCallout(warning, caption: true).accessibilityIdentifier("panel-brief-warning")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(PanelStyle.card, in: RoundedRectangle(cornerRadius: LoamTheme.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: LoamTheme.radiusMd).strokeBorder(LoamColor.hairline))
    }

    /// What and Why: plain text under a heading. The text becomes an editor when you click it.
    private func plainBrief(_ field: BriefField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelSectionHeader(title: field.title)
            BriefText(model: model, window: window, field: field, size: 13, color: LoamColor.inkMuted, inset: 8)
            briefButtons(field).padding(.horizontal, 8)
        }
    }

    @ViewBuilder private func briefButtons(_ field: BriefField) -> some View {
        if model.isDirty(field) {
            TrailingButtons {
                Button("Revert") { model.revert(field) }
                    .accessibilityIdentifier("panel-revert-\(field.rawValue)")
                Button("Save") { Task { await model.save(field) } }
                    .loamPrimaryButton()
                    .accessibilityIdentifier("panel-save-\(field.rawValue)")
            }
        }
    }

    // MARK: Repos

    private func repos(_ plot: Plot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelSectionHeader(title: "Repos", add: ("Add repo", "panel-add-repo-open")) { open(.repo) }
            ForEach(plot.repos) { repo in
                HoverMenuRow(menuLabel: "Repo actions", menuID: "panel-repo-menu-\(repo.id)", kind: repo.main ? "Main" : nil) {
                    RepoRowContent(repo: repo)
                } actions: {
                    Button("Remove repo", role: .destructive) { Task { await model.removeRepo(id: repo.id) } }
                }
                .accessibilityIdentifier("panel-repo-\(repo.id)")
            }
            if adding == .repo {
                addRepoRow.padding(.horizontal, 8).padding(.vertical, 4)
            } else if plot.repos.isEmpty {
                EmptyRow(text: "No repos")
            }
        }
    }

    /// Ticket 78: type a name or a path. The rows under the field are the repos of other plots and the
    /// git checkouts next to them. Return on a name adds the first row. Choose opens a folder picker.
    private var addRepoRow: some View {
        let suggestions = model.repoSuggestions(matching: newRepo)
        let returnPicksFirst = Self.filled(newRepo) && !AddSources.isPath(newRepo)
        return VStack(alignment: .leading, spacing: LoamTheme.space2) {
            TextField("Repo", text: $newRepo, prompt: Text("Name or path"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .newRepo)
                .onSubmit(addRepo)
                .onKeyPress(.escape) { closeEditors(); return .handled }
                .accessibilityIdentifier("panel-new-repo")
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                RepoSuggestionRow(suggestion: suggestion, returnAdds: returnPicksFirst && index == 0) {
                    addRepo(path: suggestion.path)
                }
            }
            addButtons(id: "panel-add-repo", enabled: Self.filled(newRepo), add: addRepo) { chooseRepo() }
        }
        .task {
            focus = .newRepo
            await model.loadRepoSuggestions()
        }
    }

    private func addRepo() {
        addRepo(path: model.repoPath(forInput: newRepo))
    }

    private func addRepo(path: String) {
        guard !addBusy, Self.filled(path) else { return }
        addBusy = true
        Task {
            await model.addRepo(path: path)
            addBusy = false
            // Close the row only if it is still the open one, so an editor opened meanwhile stays.
            if model.errorMessage == nil, adding == .repo { closeEditors() }
        }
    }

    // MARK: Links

    private func links(_ plot: Plot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelSectionHeader(title: "Links", add: ("Add link", "panel-add-link-open")) { open(.link) }
            ForEach(plot.links) { link in
                if editingLink == link.id {
                    linkEditor(link).padding(.horizontal, 8).padding(.vertical, 4)
                } else {
                    HoverMenuRow(menuLabel: "Link actions", menuID: "panel-link-menu-\(link.id)", kind: link.kindLabel) {
                        LinkRow(link: link, missing: model.isMissing(link)) {
                            Task { await model.open(linkID: link.id) }
                        }
                    } actions: {
                        linkActions(link)
                    }
                    .accessibilityIdentifier("panel-link-row-\(link.id)")
                }
            }
            if adding == .link {
                addLinkRow.padding(.horizontal, 8).padding(.vertical, 4)
            } else if plot.links.isEmpty {
                EmptyRow(text: "No links")
            }
        }
    }

    @ViewBuilder private func linkActions(_ link: PlotLink) -> some View {
        Button("Copy target") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.target, forType: .string)
        }
        if link.kind == .path || link.kind == .vault {
            Button("Reveal in Finder") {
                let path = (link.target as NSString).expandingTildeInPath
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        Divider()
        Button("Edit link") { beginEditing(link) }
        Button("Remove link", role: .destructive) { Task { await model.removeLink(id: link.id) } }
    }

    /// Ticket 78: the target comes first, and the label is optional. With no label, the core takes one
    /// from the target. Choose opens a file picker and adds the link at once.
    private var addLinkRow: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            TextField("Target", text: $newTarget, prompt: Text("URL or path"))
                .focused($focus, equals: .newTarget)
                .accessibilityIdentifier("panel-new-link-target")
            TextField("Label", text: $newLabel, prompt: Text("Label (optional)"))
                .accessibilityIdentifier("panel-new-link-label")
            addButtons(id: "panel-add-link", enabled: Self.filled(newTarget), add: addLink) { chooseLinkTarget() }
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .onSubmit(addLink)
        .onKeyPress(.escape) { closeEditors(); return .handled }
        .task { focus = .newTarget }
    }

    private func addLink() { addLink(target: newTarget) }

    private func addLink(target: String) {
        let label = newLabel
        guard !addBusy, Self.filled(target) else { return }
        addBusy = true
        Task {
            await model.addLink(label: label, target: target)
            addBusy = false
            if model.errorMessage == nil, adding == .link { closeEditors() }
        }
    }

    private func beginEditing(_ link: PlotLink) {
        closeEditors()
        linkLabel = link.label
        linkTarget = link.target
        linkNote = link.note
        editingLink = link.id
    }

    private func linkEditor(_ link: PlotLink) -> some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            TextField("Label", text: $linkLabel, prompt: Text("Label"))
                .focused($focus, equals: .linkLabel)
                .accessibilityIdentifier("panel-edit-link-label")
            TextField("Target", text: $linkTarget, prompt: Text("URL or path"))
                .accessibilityIdentifier("panel-edit-link-target")
            TextField("Note", text: $linkNote, prompt: Text("Note"))
            TrailingButtons {
                Button("Cancel", action: closeEditors)
                    .accessibilityIdentifier("panel-edit-link-cancel")
                Button("Save") { saveLink(link) }
                    .loamPrimaryButton()
                    .disabled(!Self.filled(linkLabel, linkTarget) || addBusy)
                    .accessibilityIdentifier("panel-edit-link-save")
            }
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .onSubmit { saveLink(link) }
        .onKeyPress(.escape) { closeEditors(); return .handled }
        .task { focus = .linkLabel }
    }

    /// Saves the link editor. The editor stays open until the write succeeds, so an error keeps
    /// what you typed.
    private func saveLink(_ link: PlotLink) {
        let (label, target, note) = (linkLabel, linkTarget, linkNote)
        guard !addBusy, Self.filled(label, target) else { return }
        addBusy = true
        Task {
            await model.editLink(id: link.id, label: label, target: target, note: note)
            addBusy = false
            if model.errorMessage == nil, model.clash == nil, editingLink == link.id { closeEditors() }
        }
    }

    // MARK: Add rows

    /// Choose at the leading edge, then Cancel and Add.
    private func addButtons(id: String, enabled: Bool, add: @escaping () -> Void, choose: @escaping () -> Void) -> some View {
        HStack {
            Button("Choose\u{2026}", action: choose)
                .disabled(addBusy)
                .accessibilityIdentifier("\(id)-choose")
            Spacer()
            Button("Cancel", action: closeEditors)
                .accessibilityIdentifier("panel-add-cancel")
            Button("Add", action: add)
                .loamPrimaryButton()
                .disabled(!enabled || addBusy)
                .accessibilityIdentifier(id)
        }
        .controlSize(.small)
    }

    /// A folder picker that opens next to the main repo, or in the first suggestion folder.
    private func chooseRepo() {
        let start = model.plot?.repos.first { $0.main }.map { ($0.path as NSString).deletingLastPathComponent }
            ?? model.suggestionRoots.first { FileManager.default.fileExists(atPath: $0) }
        pick(folders: true, files: false, start: start, prompt: "Add repo") { addRepo(path: $0) }
    }

    /// A file and folder picker that opens in the main repo.
    private func chooseLinkTarget() {
        let start = model.plot?.repos.first { $0.main }?.path
        pick(folders: true, files: true, start: start, prompt: "Add link") { addLink(target: $0) }
    }

    /// Shows an open panel as a sheet on the panel's window, and calls `chosen` with the path.
    private func pick(folders: Bool, files: Bool, start: String?, prompt: String, chosen: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = files
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        if let start { panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true) }
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            chosen(url.path)
        }
        if let window = window.window {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(panel.runModal())
        }
    }

    /// True when each text has more than white space.
    private static func filled(_ texts: String...) -> Bool {
        texts.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func open(_ row: AddRow) {
        closeEditors()
        adding = row
    }

    /// Closes the add rows and the link editor, and clears what they held.
    private func closeEditors() {
        adding = nil
        editingLink = nil
        newRepo = ""
        newLabel = ""
        newTarget = ""
        focus = nil
    }
}

/// What the panel waits on before it runs a request from the actions menu.
private struct PanelRequestKey: Equatable {
    var request: PanelRequest?
    var plot: String?
}

// MARK: Style

extension LoamColor {
    /// A hairline: the ink at 8%. Structure is felt, not seen.
    static var hairline: Color { ink.opacity(0.08) }
    /// The neutral fill of a hovered row: the ink at 6%.
    static var hoverFill: Color { ink.opacity(0.06) }
    /// The fill of a chip and a small round control: the ink at 10%.
    static var chipFill: Color { ink.opacity(0.10) }
    /// The fill of an avatar: the ink at 7%.
    static var cardFill: Color { ink.opacity(0.07) }
}

/// What the plot panel stands on, and the card on it. One place, so the choice is easy to change.
@MainActor enum PanelStyle {
    /// The raised card (Where it stands): one step above the panel ground.
    static var card: Color { LoamColor.horizonB }
}

/// The ground of the plot panel: the same material as the glass sidebar (ticket 87).
struct PanelGround: View {
    var body: some View {
        LoamColor.panelGround
    }
}

// MARK: Rows

/// A brief field: the text of What, Why, or Where it stands. It reads as plain text. A hover or the
/// focus gives it a neutral fill, and a click makes it an editor. A multiline field commits on Return and selects
/// all its text, so Return adds a new line as in the old text editor, and Command-Return saves.
struct BriefText: View {
    let model: PlotPanelModel
    let window: WindowRef
    let field: BriefField
    let size: CGFloat
    let color: Color
    /// The padding inside the fill. A field in a card has none.
    let inset: CGFloat
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(field.title, text: Binding(
            get: { model.shownText(of: field) },
            set: { model.edit(field, to: $0) }), prompt: Text(Self.placeholder(field)), axis: .vertical)
            .labelsHidden()
            .textFieldStyle(.plain)
            .loamText(LoamTheme.bodyStyle, color)
            .font(.system(size: size))
            .lineLimit(1...)
            .focused($focused)
            .onKeyPress(keys: [.return], phases: .down) { press in
                if press.modifiers.contains(.command) {
                    Task { await model.save(field) }
                    return .handled
                }
                // During input method composition, Return commits the composed text.
                guard let editor = (window.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView,
                      !editor.hasMarkedText() else { return .ignored }
                editor.insertNewlineIgnoringFieldEditor(nil)
                return .handled
            }
            .padding(.horizontal, inset)
            .padding(.vertical, inset == 0 ? 0 : 4)
            .background(
                RoundedRectangle(cornerRadius: LoamTheme.radiusSm).fill(LoamColor.hoverFill)
                    .opacity(inset > 0 && (hovering || focused) ? 1 : 0))
            .onHover { hovering = $0 }
            .animation(LoamAnimation.fast, value: hovering)
            .accessibilityIdentifier("panel-\(field.rawValue)")
            // Edit brief from the actions menu (ticket 89) puts the cursor in What.
            .task(id: model.readyRequest) {
                guard field == .what, model.readyRequest == .editBrief else { return }
                model.request = nil
                for _ in 0..<5 {
                    focused = true
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
    }

    private static func placeholder(_ field: BriefField) -> String {
        switch field {
        case .what: "What this plot is"
        case .why: "Why this plot matters"
        case .whereItStands: "Where the work stands"
        }
    }
}

/// A label and a value on one 28pt row: the label in `ink-faint`, the value in `ink`.
struct PropertyRow<Value: View>: View {
    let label: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(LoamColor.inkFaint).frame(width: 84, alignment: .leading)
            HStack(spacing: 6) { value() }.foregroundStyle(LoamColor.ink)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
        .frame(height: 28)
        .accessibilityElement(children: .combine)
    }
}

/// A section heading: sentence case, 12pt, medium, `ink-faint`. With `add`, a `+` at the trailing edge
/// opens an inline add row.
struct PanelSectionHeader: View {
    let title: String
    var add: (label: String, id: String)?
    var action: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LoamColor.inkFaint)
            Spacer()
            if let add {
                Button(action: action) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(LoamColor.hoverFill).opacity(hovering ? 1 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(hovering ? LoamColor.ink : LoamColor.inkFaint)
                .onHover { hovering = $0 }
                .help(add.label)
                .accessibilityLabel(add.label)
                .accessibilityIdentifier(add.id)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 20)
    }
}

/// A row of small native buttons at the trailing edge. In a callout (`pill`) they are small pills.
struct TrailingButtons<Content: View>: View {
    var pill = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 6) {
            Spacer()
            if pill {
                content().buttonStyle(PanelPillStyle())
            } else {
                content()
            }
        }
        .controlSize(.small)
    }
}

/// A small pill button, as the Needs you banner of the prototype has.
struct PanelPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(LoamColor.chipFill.opacity(configuration.isPressed ? 1.6 : 1)))
            .contentShape(Capsule())
    }
}

/// The row of an empty section, in `ink-faint`.
struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(LoamColor.inkFaint)
            .padding(.horizontal, 8)
            .frame(height: 28, alignment: .leading)
    }
}

/// A banner at the top of the panel, as the prototype's Needs you banner: a wash, radius 10, and a dot.
struct CalloutCard<Content: View>: View {
    enum Tone { case attention, error }
    var tone: Tone = .attention
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tone == .error ? LoamColor.rust : LoamColor.needsYou)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LoamTheme.space2) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.vertical, 9)
        .background(tone == .error ? LoamColor.rustWash : LoamColor.needsYouWash,
                    in: RoundedRectangle(cornerRadius: LoamTheme.radiusMd))
    }
}

/// A callout line: the message in `ink`. The dot of the card carries the colour. A callout with its
/// own symbol (a missing folder) shows it in `rust`.
struct PanelCallout: View {
    let message: String
    let symbol: String?
    let emphasis: Bool
    let caption: Bool

    init(_ message: String, symbol: String? = nil, emphasis: Bool = false, caption: Bool = false) {
        self.message = message
        self.symbol = symbol
        self.emphasis = emphasis
        self.caption = caption
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol { Image(systemName: symbol).foregroundStyle(LoamColor.rust) }
            Text(message)
                .font(.system(size: caption ? 11.5 : 12.5, weight: emphasis ? .semibold : .regular))
                .foregroundStyle(caption ? LoamColor.inkMuted : LoamColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A titled value in a callout: the title in `ink-muted` `caption`, then the text, which you can select.
struct CalloutText: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            Text(text).font(.system(size: 12.5)).foregroundStyle(LoamColor.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A 32pt row with a neutral fill on hover. At the trailing edge it shows its kind ("Main", "GitHub")
/// and, while the pointer or the keyboard is on it, an `ellipsis` menu in place of the kind. Its context
/// menu holds the same actions.
struct HoverMenuRow<Content: View, Actions: View>: View {
    let menuLabel: String
    let menuID: String
    var kind: String?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false
    /// With full keyboard access, Tab can reach the menu. It shows while it has the focus.
    @FocusState private var menuFocused: Bool

    var body: some View {
        let active = hovering || menuFocused
        ZStack(alignment: .trailing) {
            content()
                .padding(.trailing, 56)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let kind {
                Text(kind)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LoamColor.inkFaint)
                    .opacity(active ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(LoamColor.inkMuted)
            .focused($menuFocused)
            .opacity(active ? 1 : 0)
            .help(menuLabel)
            .accessibilityLabel(menuLabel)
            .accessibilityIdentifier(menuID)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background(RoundedRectangle(cornerRadius: LoamTheme.radiusSm).fill(LoamColor.hoverFill).opacity(active ? 1 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(LoamAnimation.fast, value: active)
        .contextMenu { actions() }
        // The hidden menu leaves the accessibility tree, so the row names the same actions.
        .accessibilityElement(children: .contain)
        .accessibilityActions { actions() }
    }
}

/// One repo of a plot: a 16pt branch symbol and the folder name in `ink`. The path is the tooltip.
struct RepoRowContent: View {
    let repo: Repo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LoamColor.inkMuted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text((repo.path as NSString).lastPathComponent)
                    .font(.system(size: 13))
                    .foregroundStyle(LoamColor.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !repo.note.isEmpty {
                    Text(repo.note).font(.system(size: 11.5)).foregroundStyle(LoamColor.inkFaint).lineLimit(1)
                }
            }
        }
        .help((repo.path as NSString).abbreviatingWithTildeInPath)
    }
}

/// A repo that the add repo row offers: the folder name, then the path in `ink-muted`. A press adds
/// it. `returnAdds` marks the row that Return adds.
struct RepoSuggestionRow: View {
    let suggestion: RepoSuggestion
    let returnAdds: Bool
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space2) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(LoamColor.inkMuted)
                Text(suggestion.name).loamText(LoamTheme.bodyStyle).fixedSize()
                Text(suggestion.shownPath)
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if returnAdds {
                    Image(systemName: "return").foregroundStyle(LoamColor.inkMuted).help("Return adds this repo")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(suggestion.path)
        .accessibilityLabel("Add \(suggestion.name), \(suggestion.shownPath)")
        .accessibilityIdentifier("panel-repo-suggestion-\(suggestion.name)")
    }
}

/// One link of a plot (docs/design/components/LinkRow): a 16pt kind icon in `ink-muted` and the label
/// in `ink`. The whole row opens the link. A local link whose path is gone shows the label struck
/// through in `rust`.
struct LinkRow: View {
    let link: PlotLink
    let missing: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                LoamIconView(icon: link.icon, size: 13, color: missing ? LoamColor.rust : LoamColor.inkMuted)
                    .frame(width: 16)
                    .help(link.chipName)
                VStack(alignment: .leading, spacing: 1) {
                    Text(link.label)
                        .font(.system(size: 13))
                        .foregroundStyle(missing ? LoamColor.rust : LoamColor.ink)
                        .strikethrough(missing, color: LoamColor.rust)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    if !link.note.isEmpty {
                        Text(link.note).font(.system(size: 11.5)).foregroundStyle(LoamColor.inkFaint).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("panel-link-\(link.id)")
        .accessibilityLabel(missing ? "\(link.label), \(link.chipName), path missing" : "\(link.label), \(link.chipName)")
    }
}

/// A weak reference to the window that holds a SwiftUI view.
final class WindowRef {
    weak var window: NSWindow?
}

/// Puts the window of its view into `ref`, and keeps it current when the view moves.
struct WindowReader: NSViewRepresentable {
    let ref: WindowRef

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.ref = ref
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) { view.ref = ref }

    final class ReaderView: NSView {
        var ref: WindowRef?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            ref?.window = window
        }
    }
}
