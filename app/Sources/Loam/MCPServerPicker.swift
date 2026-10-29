import LoamKit
import SwiftUI

/// The MCP servers of the run defaults, as a menu with a checkmark for each selected server. It sits in the row of
/// `ModelEffortPickers` and has the same column. A selected server that the list lacks stays selected and shows
/// "not found" until you clear it. `servers` is nil when the list could not be read.
struct MCPServerPicker: View {
    let servers: [MCPServer]?
    @Binding var selected: [String]
    /// The accessibility ID.
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MCP servers").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            Menu {
                if let servers {
                    let items = MCPChoices.items(servers: servers, selected: selected)
                    if items.isEmpty {
                        Text("No MCP servers in the user scope")
                    }
                    ForEach(items) { item in
                        Toggle(item.title, isOn: Binding(
                            get: { item.isSelected },
                            set: { _ in selected = MCPChoices.toggled(item.name, in: selected) }))
                    }
                }
            } label: {
                Text(MCPChoices.label(count: selected.count))
            }
            .disabled(servers == nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(servers == nil ? "Loam could not read the MCP servers" : "The MCP servers that Claude loads when it drafts a run and writes its PR text")
            .accessibilityIdentifier(id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
