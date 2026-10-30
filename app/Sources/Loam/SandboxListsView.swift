import LoamKit
import SwiftUI

/// The paths and hosts that you add to the sandbox of a run: three lists, each with its items and a field to add
/// one. The core checks an item, and the reason for a refusal shows under the lists. `scope` names the page in the
/// accessibility IDs ("plot" or "machine").
struct SandboxListsView: View {
    let model: SandboxSettingsModel
    let scope: String

    var body: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space3) {
            ForEach(SandboxList.allCases, id: \.self) { list in
                SandboxListRow(model: model, list: list, scope: scope)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .loamText(LoamTheme.captionStyle, LoamColor.rust)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sandbox-\(scope)-error")
            }
        }
        .disabled(model.settings == nil)
        .task { await model.load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sandbox-\(scope)")
    }
}

/// One list: its title, its items with a remove button, and a field with an Add button.
private struct SandboxListRow: View {
    let model: SandboxSettingsModel
    let list: SandboxList
    let scope: String
    @State private var text = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(list.title).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.items(list), id: \.self) { item in
                    HStack(spacing: LoamTheme.space2) {
                        Text(item).loamText(LoamTheme.codeStyle).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            Task { await model.remove(list, item) }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(LoamColor.inkMuted)
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(item)")
                        .accessibilityLabel("Remove \(item)")
                        .accessibilityIdentifier("sandbox-\(scope)-\(list.rawValue)-remove-\(item)")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    Divider()
                }
                if model.items(list).isEmpty {
                    Text("None").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                    Divider()
                }
                HStack(spacing: LoamTheme.space2) {
                    TextField(list.placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit(add)
                        .accessibilityIdentifier("sandbox-\(scope)-\(list.rawValue)-field")
                    Button("Add", action: add)
                        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("sandbox-\(scope)-\(list.rawValue)-add")
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .background(LoamColor.inkFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LoamColor.inkHairline))
            Text(list.caption).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sandbox-\(scope)-\(list.rawValue)")
    }

    /// A saved item clears the field. A refused item stays in it with the reason under the lists, so you can fix it.
    private func add() {
        let item = text
        guard !busy, !item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        Task {
            if await model.add(list, item) { text = "" }
            busy = false
        }
    }
}
