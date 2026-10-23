import AppKit
import LoamKit
import SwiftUI

/// The Land sheet (ticket 112, boards 3.1 to 3.3): a card of 560 pt on `horizon-a` with `radius-lg` and
/// `shadow-switcher`, over a dim scrim. It drops in from the toolbar. It lists each check of `loam worktree land
/// --dry-run`, the merge method, the three boxes for after the merge, and the Where it stands text. The primary
/// button is off while any row blocks. `LandSheetContent` says what it shows. It is an overlay in the window, like
/// the PR popover, so the keys of the window reach it and the driver can press its buttons.
struct LandSheetView: View {
    let app: AppModel
    @FocusState private var focus: Field?
    /// False until the card has dropped in. Reset each time the sheet opens.
    @State private var arrived = false
    @State private var selection: TextSelection?
    /// The window of the sheet. The Return handlers read its first responder, so they do not depend on `@FocusState`,
    /// which can be a short time behind the window, or on the key window, which an inactive app does not have.
    @State private var window = WindowRef()

    enum Field: Hashable { case sheet, editor }

    static let width: CGFloat = 560

    var body: some View {
        let sheet = app.landSheet
        ZStack(alignment: .top) {
            SheetScrim(arrived: arrived) { app.closeLandSheet() }
            if sheet.isOpen {
                card(sheet)
                    .padding(.top, 8)
                    .opacity(arrived ? 1 : 0)
                    .offset(y: arrived || LoamMotion.reduceMotion ? 0 : -24)
            }
        }
        .background(WindowReader(ref: window))
        .focusable()
        .focused($focus, equals: .sheet)
        .focusEffectDisabled()
        // During input method composition in the box, Escape cancels the composed text, so it must not close the sheet.
        .onKeyPress(.escape) {
            if fieldEditor?.hasMarkedText() == true { return .ignored }
            app.closeLandSheet()
            return .handled
        }
        // Tab and Shift-Tab keep the keys in the sheet. The Where it stands box is its one field: Tab from the card goes to the
        // box, and the box keeps the keys. Without this, Shift-Tab leaves the sheet (ticket 123).
        .overlayTabKeys(composing: { window.isComposing }) { _ in
            if showsBox { focus = .editor }
            return true
        }
        // Only a first press of Return merges, and never one that the box takes. The box returns `.ignored` while an input
        // method has marked text, so a Return that commits that text must not reach the merge. The window says whether the
        // box has the keys (its field editor is a text view), because `focus` can be a short time behind it.
        .onKeyPress(.return, phases: .down) { _ in
            guard focus != .editor, fieldEditor == nil else { return .ignored }
            merge()
            return .handled
        }
        .task(id: sheet.openCount) {
            guard app.landSheet.isOpen else { return }
            arrived = false
            selection = nil
            withAnimation(LoamAnimation.arrive) { arrived = true }
            // The hosting view becomes first responder after this view appears.
            for _ in 0..<5 {
                guard app.landSheet.isOpen else { return }
                focus = .sheet
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        // The box is off while the merge runs, and a box that is off loses the keys to the window, where no key of the sheet
        // works. After a merge that GitHub refused, the card takes the keys, as at the open: Return merges again, and Tab goes
        // to the box (ticket 123).
        .onChange(of: sheet.isMerging) { if !app.landSheet.isMerging, app.landSheet.isOpen { focus = .sheet } }
        // The sentence about the merge is selected when the box takes the keys, so one key replaces it.
        .onChange(of: focus) {
            guard focus == .editor, app.landSheet.whereText.hasPrefix(app.landSheet.whereSentence) else { return }
            selectSentence()
        }
    }

    /// The text view that has the keys in the window of the sheet: the field editor of the Where it stands box. The sheet
    /// itself, the terminal and a callout that you select are not.
    private var fieldEditor: NSTextView? {
        LandSheetKeys.editor(of: (window.window ?? NSApp.keyWindow)?.firstResponder)
    }

    /// True when the Where it stands box shows and is on: the plan is read, the PR is not merged yet, the third box is on,
    /// and no merge runs.
    private var showsBox: Bool {
        let sheet = app.landSheet
        guard case .plan = sheet.phase, let content = app.landContent, !content.isMerged, !sheet.isMerging else { return false }
        return sheet.movesWhereItStandsOn && content.canMoveWhereItStandsOn
    }

    /// Return, or a click on the primary button. The model does nothing while a check blocks.
    private func merge() {
        Task { await app.land() }
    }

    private func selectSentence() {
        let sheet = app.landSheet
        let text = sheet.whereText
        guard !sheet.whereSentence.isEmpty, text.hasPrefix(sheet.whereSentence) else { return }
        let end = text.index(text.startIndex, offsetBy: sheet.whereSentence.count)
        selection = TextSelection(range: text.startIndex..<end)
    }

    // MARK: Card

    private func card(_ sheet: LandSheetModel) -> some View {
        let content = app.landContent
        let pr = sheet.worktreeID.flatMap { app.worktreeStatus($0)?.pr }
        return VStack(alignment: .leading, spacing: 18) {
            heading(content, pr: pr)
            switch sheet.phase {
            case .loading: loading
            case .failed(let message): problem(message, id: "land-sheet-read-error")
            case .plan: if let content { plan(content, sheet) }
            }
            if let error = sheet.landError { problem(error, id: "land-sheet-error") }
            footer(sheet, content, pr: pr)
        }
        .sheetCard(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content?.title ?? pr.map(LandSheetContent.title(of:)) ?? "Land")
        .accessibilityIdentifier("land-sheet")
    }

    /// The title and the branch line. The row of the worktree gives them while the plan loads.
    private func heading(_ content: LandSheetContent?, pr: PullRequest?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(content?.title ?? pr.map(LandSheetContent.title(of:)) ?? "Land")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LoamColor.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("land-sheet-title")
            if let line = content?.subtitle ?? pr.map(LandSheetContent.subtitle(of:)) {
                Text(line)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LoamColor.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("land-sheet-subtitle")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 4) {
            label("Before you merge")
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text("Reading the pull request\u{2026}").foregroundStyle(LoamColor.inkMuted)
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .overlay(alignment: .top) { LoamColor.inkHairline.frame(height: 1) }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("land-sheet-loading")
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(LoamColor.inkFaint)
    }

    /// A `rust` callout: GitHub's message for a merge that failed, or the reason the plan could not be read.
    private func problem(_ message: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(LoamColor.rust).frame(width: 6, height: 6).offset(y: -1)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(LoamColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LoamColor.rustWash, in: RoundedRectangle(cornerRadius: LoamTheme.radiusMd))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityIdentifier(id)
    }

    // MARK: Plan

    private func plan(_ content: LandSheetContent, _ sheet: LandSheetModel) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if !content.rows.isEmpty { checklist(content, sheet) }
            if content.mergeMethods.count > 0 { method(content, sheet) }
            if !content.isMerged { after(content, sheet) }
        }
        // The checklist locks while the merge runs.
        .disabled(sheet.isMerging)
    }

    private func checklist(_ content: LandSheetContent, _ sheet: LandSheetModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            label("Before you merge")
            VStack(spacing: 0) {
                ForEach(content.rows) { row in rowView(row, sheet) }
            }
            .overlay(alignment: .top) { LoamColor.inkHairline.frame(height: 1) }
        }
    }

    private func rowView(_ row: LandSheetContent.Row, _ sheet: LandSheetModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color(of: row.tone))
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(row.title).lineLimit(1)
            if row.hasTrailing, !row.value.isEmpty { value(row.value) }
            Spacer(minLength: 8)
            if !row.hasTrailing, !row.value.isEmpty { value(row.value) }
            if let action = row.action {
                Button { run(action) } label: {
                    HStack(spacing: 6) {
                        Text(action.title)
                        if action == .updateBranch, sheet.isUpdating {
                            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 10, height: 10)
                        }
                    }
                }
                .buttonStyle(PanelPillStyle())
                .disabled(action == .updateBranch && sheet.isUpdating)
                .accessibilityIdentifier("land-sheet-action-\(row.id)")
            } else if let hint = row.hint {
                Text(hint).font(.system(size: 12)).foregroundStyle(LoamColor.rust).lineLimit(1)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(LoamColor.ink)
        .frame(height: 30)
        .overlay(alignment: .bottom) { LoamColor.inkHairline.frame(height: 1) }
        .accessibilityElement(children: .contain)
        // The mark and the rust colour carry the state for the eye, so the label says it in words.
        .accessibilityLabel(([row.title, row.value, row.hint].compactMap { $0 }.filter { !$0.isEmpty }
                             + (row.tone == .blocking ? ["blocks the merge"] : [])).joined(separator: ", "))
        .accessibilityIdentifier("land-sheet-row-\(row.id)")
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(LoamColor.inkMuted).lineLimit(1)
    }

    private func color(of tone: LandSheetContent.Tone) -> Color {
        tone == .blocking ? LoamColor.rust : LoamColor.inkMuted
    }

    private func run(_ action: LandSheetContent.RowAction) {
        switch action {
        case .send(let kind): Task { await app.sendFromLandSheet(kind) }
        case .updateBranch: Task { await app.updateBranchFromLandSheet() }
        case .openOnGitHub:
            if let page = app.landSheet.worktreeID.flatMap({ app.worktreeStatus($0)?.githubPage }) { SystemActions.open(page) }
        }
    }

    // MARK: Method

    private func method(_ content: LandSheetContent, _ sheet: LandSheetModel) -> some View {
        let chosen = sheet.effectiveMethod(for: content)
        return HStack(spacing: 12) {
            Text("Merge method").foregroundStyle(LoamColor.inkMuted).frame(width: 96, alignment: .leading)
            Picker("Merge method", selection: Binding(get: { chosen ?? content.mergeMethods[0] }, set: { sheet.method = $0 })) {
                ForEach(content.mergeMethods, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("land-sheet-method")
            Text(chosen == content.defaultMethod ? "From the repo setting" : "Not the repo setting")
                .font(.system(size: 11))
                .foregroundStyle(LoamColor.inkFaint)
                .accessibilityIdentifier("land-sheet-method-note")
        }
        .font(.system(size: 13))
    }

    // MARK: After the merge

    private func after(_ content: LandSheetContent, _ sheet: LandSheetModel) -> some View {
        let moves = sheet.movesWhereItStandsOn && content.canMoveWhereItStandsOn
        return VStack(alignment: .leading, spacing: 8) {
            label("After the merge")
            if let note = content.afterNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(LoamColor.inkMuted)
                    .accessibilityIdentifier("land-sheet-after-note")
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { sheet.removesWorktree }, set: { sheet.removesWorktree = $0 })) {
                    Text("\(content.removeLabel) \(Text(content.worktreeName).font(.system(size: 12, design: .monospaced)))")
                }
                .accessibilityIdentifier("land-sheet-remove")
                Toggle("Delete the branch on GitHub", isOn: Binding(get: { sheet.deletesBranch }, set: { sheet.deletesBranch = $0 }))
                    .accessibilityIdentifier("land-sheet-delete-branch")
                Toggle("Move Where it stands on", isOn: Binding(get: { moves }, set: { sheet.movesWhereItStandsOn = $0 }))
                    .disabled(!content.canMoveWhereItStandsOn)
                    .accessibilityIdentifier("land-sheet-move-on")
                if moves { whereItStands(sheet) }
                // The plot link that the work started from (ticket 115).
                if let label = content.removeLinkLabel {
                    Toggle(label, isOn: Binding(get: { sheet.removesLink }, set: { sheet.removesLink = $0 }))
                        .accessibilityIdentifier("land-sheet-remove-link")
                }
            }
            .toggleStyle(.checkbox)
            .tint(LoamColor.moss)
            .font(.system(size: 13))
            .foregroundStyle(LoamColor.ink)
        }
    }

    /// The box under the third checkbox. Return adds a line, and Command-Return merges, as Command-Return saves a
    /// field of the plot panel.
    private func whereItStands(_ sheet: LandSheetModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Where it stands", text: Binding(get: { sheet.whereText }, set: { sheet.whereText = $0 }),
                      selection: $selection, axis: .vertical)
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineLimit(3...6)
                .focused($focus, equals: .editor)
                // A held Return repeats. The repeats add lines too: with no handler, the field takes a Return as a commit and
                // selects all its text, and the next letter would replace the text.
                .onKeyPress(keys: [.return], phases: [.down, .repeat]) { press in
                    if press.modifiers.contains(.command) {
                        // A held Command-Return merges once.
                        if press.phase == .down { merge() }
                        return .handled
                    }
                    // During input method composition, Return commits the composed text.
                    guard let editor = fieldEditor, !editor.hasMarkedText() else { return .ignored }
                    editor.insertNewlineIgnoringFieldEditor(nil)
                    return .handled
                }
                // During input method composition, Escape cancels the composed text.
                .onKeyPress(.escape) {
                    if fieldEditor?.hasMarkedText() == true { return .ignored }
                    app.closeLandSheet()
                    return .handled
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                // The Where it stands card of the plot panel: `horizon-b`, `radius-md` and a hairline (ticket 120).
                .loamFieldBox(LoamColor.horizonB, radius: LoamTheme.radiusMd)
                .accessibilityIdentifier("land-sheet-where")
            Text("Loam saves this as a change. You can undo it.")
                .font(.system(size: 11))
                .foregroundStyle(LoamColor.inkMuted)
                .accessibilityIdentifier("land-sheet-where-note")
        }
        .padding(.leading, 24)
    }

    // MARK: Footer

    private func footer(_ sheet: LandSheetModel, _ content: LandSheetContent?, pr: PullRequest?) -> some View {
        HStack(spacing: 8) {
            Text(sheet.isMerging ? "You cannot undo a merge." : content?.footer ?? "")
                .font(.system(size: 12))
                .foregroundStyle(LoamColor.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("land-sheet-footer")
            // A native button at the size of the primary button, so the two share one shape (ticket 120).
            Button("Cancel") { app.closeLandSheet() }
                .loamSecondaryButton()
                .controlSize(.large)
                .disabled(sheet.isMerging)
                .accessibilityIdentifier("land-sheet-cancel")
            Button { merge() } label: {
                HStack(spacing: 8) {
                    if sheet.isMerging { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12) }
                    Text(primaryTitle(sheet, content, pr: pr))
                }
            }
            .loamPrimaryButton()
            .controlSize(.large)
            .disabled(!(content?.canMerge ?? false) && !sheet.isMerging)
            .accessibilityIdentifier("land-sheet-merge")
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { LoamColor.inkHairline.frame(height: 1) }
    }

    private func primaryTitle(_ sheet: LandSheetModel, _ content: LandSheetContent?, pr: PullRequest?) -> String {
        if sheet.isMerging { return "Merging\u{2026}" }
        return content?.primaryTitle ?? pr.map { "Merge #\($0.number)" } ?? "Merge"
    }
}
