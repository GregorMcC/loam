import AppKit
import LoamKit
import SwiftUI

/// The New worktree sheet (ticket 115, board NewWorktreeSheet): a card of 560 pt on `horizon-a` with `radius-lg` and
/// `shadow-switcher`, over a dim scrim, as the Land sheet draws it. It asks for the repo, the branch, the base, the goal
/// and the link of a new worktree, checks the branch as you type, and starts a seeded session in the worktree. A link
/// card at the top shows the issue when the sheet starts from a link. `NewWorktreeContent` says what it shows. It is an
/// overlay in the window, like the Land sheet, so the keys of the window reach it and the driver can press its buttons.
struct NewWorktreeSheetView: View {
    let app: AppModel
    @FocusState private var focus: Field?
    /// False until the card has dropped in. Reset each time the sheet opens.
    @State private var arrived = false
    /// The window of the sheet. The Return handler reads its first responder, so it does not depend on `@FocusState`,
    /// which can be a short time behind the window.
    @State private var window = WindowRef()

    enum Field: Hashable { case sheet, branch, goal, url }

    static let width: CGFloat = 560

    var body: some View {
        let sheet = app.newWorktreeSheet
        ZStack(alignment: .top) {
            SheetScrim(arrived: arrived) { app.closeNewWorktree() }
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
        .onKeyPress(.escape) {
            // Escape that cancels an input method composition is the input method's.
            guard !window.isComposing else { return .ignored }
            app.closeNewWorktree()
            return .handled
        }
        // Return starts the session, but not when a field has the keys: the field takes the Return as its own (`onSubmit`).
        .onKeyPress(.return, phases: .down) { _ in
            guard fieldEditor == nil else { return .ignored }
            start()
            return .handled
        }
        .task(id: sheet.openCount) {
            guard app.newWorktreeSheet.isOpen else { return }
            arrived = false
            withAnimation(LoamAnimation.arrive) { arrived = true }
            // The hosting view becomes first responder after this view appears. The Branch field takes the keys, so Return
            // starts a session from a link and a first key names the branch from the plus. After the first try, a control of
            // the sheet that you chose meanwhile, with a click or a Tab, keeps the keys.
            for attempt in 0..<5 {
                guard app.newWorktreeSheet.isOpen else { return }
                if attempt > 0, focus != .branch, aControlHasTheKeys { return }
                focus = .branch
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    /// The text view that has the keys in the window of the sheet: the field editor of a text field.
    private var fieldEditor: NSTextView? {
        (window.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView
    }

    /// True when a control of the sheet has the keys: a field, a popup, or the card itself after a Tab. False when the hosting
    /// view has them, as it does when the sheet opens, and when a view outside the sheet has them. At the open, the hosting
    /// view has the keys and nothing has the focus. SwiftUI does not give the card the keys on its own, so the card has them
    /// only after a Tab. The host is `NSHostingView<NewWorktreeSheetView>` (`installNewWorktreeSheet`). The `start-work`
    /// driver scenario checks this with a Tab at the open.
    private var aControlHasTheKeys: Bool {
        var view = (window.window ?? NSApp.keyWindow)?.firstResponder as? NSView
        if view is NSHostingView<NewWorktreeSheetView> { return false }
        while let current = view {
            if current is NSHostingView<NewWorktreeSheetView> { return true }
            view = current.superview
        }
        return false
    }

    /// Return, or a click on the primary button. The model does nothing while the check blocks.
    private func start() {
        Task { await app.startNewWorktree() }
    }

    // MARK: Card

    private func card(_ sheet: NewWorktreeModel) -> some View {
        let content = NewWorktreeContent(sheet)
        return VStack(alignment: .leading, spacing: 16) {
            Text(NewWorktreeContent.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LoamColor.ink)
                .accessibilityIdentifier("new-worktree-title")
            if case .failed(let message) = sheet.phase {
                problem(message, id: "new-worktree-read-error")
            } else {
                if let link = content.linkCard { linkCard(link) }
                form(sheet, content)
                    // The fields lock while the worktree is made.
                    .disabled(sheet.isStarting)
                seed(sheet, content)
            }
            if let error = sheet.startError { problem(error, id: "new-worktree-error") }
            footer(sheet, content)
        }
        .sheetCard(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NewWorktreeContent.title)
        .accessibilityIdentifier("new-worktree-sheet")
    }

    /// The issue that Start work… came from. Loam does not copy it, and the card says so.
    private func linkCard(_ card: NewWorktreeContent.LinkCard) -> some View {
        HStack(alignment: .top, spacing: 10) {
            LoamIconView(icon: .link(card.kind, target: ""), size: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LoamColor.ink)
                    .lineLimit(2)
                if !card.note.isEmpty {
                    Text(card.note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(LoamColor.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LoamColor.horizonB, in: RoundedRectangle(cornerRadius: LoamTheme.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: LoamTheme.radiusMd).strokeBorder(LoamColor.inkHairline))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("new-worktree-link-card")
    }

    // MARK: Form

    private func form(_ sheet: NewWorktreeModel, _ content: NewWorktreeContent) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                rowLabel("Repo")
                repoPopup(sheet, content)
            }
            GridRow {
                rowLabel("Branch")
                VStack(alignment: .leading, spacing: 5) {
                    TextField("Branch name", text: Binding(get: { sheet.branch }, set: { sheet.setBranch($0) }))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .focused($focus, equals: .branch)
                        .fieldBox()
                        .modifier(FieldKeys(close: { app.closeNewWorktree() }, composing: { window.isComposing }, submit: start))
                        .accessibilityLabel("Branch")
                        .accessibilityIdentifier("new-worktree-branch")
                    note(content.branchNote, id: "new-worktree-branch-note")
                }
            }
            GridRow {
                rowLabel("Base")
                basePopup(sheet, content)
            }
            GridRow {
                rowLabel("Goal")
                VStack(alignment: .leading, spacing: 5) {
                    TextField("Goal", text: Binding(get: { sheet.goal }, set: { sheet.setGoal($0) }))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focus, equals: .goal)
                        .fieldBox()
                        .modifier(FieldKeys(close: { app.closeNewWorktree() }, composing: { window.isComposing }, submit: start))
                        .accessibilityLabel("Goal")
                        .accessibilityIdentifier("new-worktree-goal")
                    note(content.goalNote, id: "new-worktree-goal-note")
                }
            }
            GridRow {
                rowLabel("Link")
                VStack(alignment: .leading, spacing: 5) {
                    linkPopup(sheet, content)
                    if sheet.linkChoice == .pasted {
                        TextField("URL of a Linear issue or a GitHub issue",
                                  text: Binding(get: { sheet.pastedURL }, set: { sheet.setPastedURL($0) }))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .focused($focus, equals: .url)
                            .fieldBox()
                            .modifier(FieldKeys(close: { app.closeNewWorktree() }, composing: { window.isComposing }, submit: start))
                            .accessibilityLabel("Link URL")
                            .accessibilityIdentifier("new-worktree-url")
                    }
                    note(content.linkNote, id: "new-worktree-link-note")
                }
            }
        }
        .font(.system(size: 13))
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(LoamColor.inkMuted)
            .frame(width: 84, height: 28, alignment: .leading)
    }

    /// A line under a field: a hint, a warning in `needs`, or a problem in `rust`.
    @ViewBuilder
    private func note(_ note: NewWorktreeContent.Note?, id: String) -> some View {
        if let note {
            Text(note.text)
                .font(.system(size: 11))
                .foregroundStyle(color(of: note.tone))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(id)
        }
    }

    private func color(of tone: NewWorktreeContent.Note.Tone) -> Color {
        switch tone {
        case .hint: LoamColor.inkMuted
        case .warning: LoamColor.needsYou
        case .problem: LoamColor.rust
        }
    }

    // MARK: Popups

    private func repoPopup(_ sheet: NewWorktreeModel, _ content: NewWorktreeContent) -> some View {
        popup(id: "new-worktree-repo", label: "Repo", title: content.repoName, tag: content.repoIsMain ? NewWorktreeContent.mainRepo : nil,
              icon: .symbol("folder")) {
            Picker("Repo", selection: Binding(get: { sheet.repoID ?? "" }, set: { sheet.chooseRepo($0) })) {
                ForEach(content.repos) { repo in
                    Text(repo.isMain ? "\(repo.name)   \(NewWorktreeContent.mainRepo)" : repo.name).tag(repo.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    /// The Base popup. A branch that exists takes no base, so the popup dims and is off.
    private func basePopup(_ sheet: NewWorktreeModel, _ content: NewWorktreeContent) -> some View {
        popup(id: "new-worktree-base", label: "Base", title: content.baseTitle, mono: true) {
            Picker("Base", selection: Binding(get: { sheet.baseChoice }, set: { sheet.chooseBase($0) })) {
                ForEach(content.baseItems, id: \.title) { item in
                    Text(item.title).tag(item.value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .disabled(!content.baseApplies)
        .opacity(content.baseApplies ? 1 : 0.45)
    }

    private func linkPopup(_ sheet: NewWorktreeModel, _ content: NewWorktreeContent) -> some View {
        let icon: LoamIcon? = sheet.chosenLink.map { .link($0.kind, target: $0.target) }
        return popup(id: "new-worktree-link", label: "Link", title: content.linkTitle, icon: icon) {
            Picker("Link", selection: Binding(get: { sheet.linkChoice }, set: { sheet.chooseLink($0) })) {
                Text(NewWorktreeContent.noLink).tag(NewWorktreeModel.LinkChoice.none)
                if !content.linkItems.isEmpty { Divider() }
                ForEach(content.linkItems) { item in Text(item.title).tag(NewWorktreeModel.LinkChoice.plot(item.id)) }
                Divider()
                Text(NewWorktreeContent.pasteLink).tag(NewWorktreeModel.LinkChoice.pasted)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    /// A popup of the board: 28 pt high, radius 6, a fill and a hairline, the chosen value, and the up and down mark.
    private func popup<Items: View>(id: String, label: String, title: String, mono: Bool = false, tag: String? = nil,
                                    icon: LoamIcon? = nil, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 8) {
                if let icon { LoamIconView(icon: icon, size: 13) }
                Text(title)
                    .font(.system(size: mono ? 12.5 : 13, design: mono ? .monospaced : .default))
                    .foregroundStyle(LoamColor.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let tag {
                    Text(tag).font(.system(size: 12)).foregroundStyle(LoamColor.inkFaint)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LoamColor.inkMuted)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(LoamColor.inkFill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LoamColor.inkHairline))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        // The borderless style keeps only the text and the image of the label. The plain button style keeps the box.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(label)
        .accessibilityValue(title)
        .accessibilityIdentifier(id)
    }

    // MARK: Seed

    /// "What the seed adds": closed at first. It shows the line that the seed of the plot gets for the worktree.
    private func seed(_ sheet: NewWorktreeModel, _ content: NewWorktreeContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(LoamAnimation.settle) { sheet.showsSeed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(sheet.showsSeed ? 90 : 0))
                        .frame(width: 9)
                    Text(NewWorktreeContent.seedTitle)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LoamColor.inkFaint)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(sheet.showsSeed ? "expanded" : "collapsed")
            .accessibilityIdentifier("new-worktree-seed")
            if sheet.showsSeed {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NewWorktreeContent.seedNote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(LoamColor.inkMuted)
                    Text(content.seedText)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(LoamColor.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(LoamColor.horizonB, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LoamColor.inkHairline))
                        .accessibilityIdentifier("new-worktree-seed-line")
                }
                .padding(.leading, 15)
            }
        }
    }

    // MARK: Problem and footer

    /// A `rust` callout: the message of the core for a worktree that was not made, or the reason the plot could not be read.
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

    private func footer(_ sheet: NewWorktreeModel, _ content: NewWorktreeContent) -> some View {
        HStack(spacing: 8) {
            Text(NewWorktreeContent.footer)
                .font(.system(size: 12))
                .foregroundStyle(LoamColor.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("new-worktree-footer")
            // A native button at the size of the primary button, so the two share one shape (ticket 120).
            Button("Cancel") { app.closeNewWorktree() }
                .loamSecondaryButton()
                .controlSize(.large)
                .disabled(sheet.isStarting)
                .accessibilityIdentifier("new-worktree-cancel")
            Button { start() } label: {
                HStack(spacing: 8) {
                    if sheet.isStarting { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12) }
                    Text(content.primaryTitle)
                }
            }
            .loamPrimaryButton()
            .controlSize(.large)
            .disabled(!sheet.canStart)
            .accessibilityIdentifier("new-worktree-start")
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { LoamColor.inkHairline.frame(height: 1) }
    }
}

/// The look of a text field of the sheet (the `.tf` of the board): 28 pt high, on `horizon-b` with `radius-sm` and a
/// hairline, as the popups beside it (ticket 120).
private extension View {
    func fieldBox() -> some View {
        padding(.horizontal, 9)
            .frame(height: 28)
            .loamFieldBox()
    }
}

/// Escape closes the sheet and Return starts the session, from inside a text field too. Escape that cancels an input
/// method composition does neither: it is the input method's.
private struct FieldKeys: ViewModifier {
    let close: () -> Void
    let composing: () -> Bool
    let submit: () -> Void

    func body(content: Content) -> some View {
        content
            .onSubmit(submit)
            .onKeyPress(.escape) {
                guard !composing() else { return .ignored }
                close()
                return .handled
            }
    }
}
