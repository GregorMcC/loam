import LoamKit
import SwiftUI

/// The Model and Effort pickers of a run. "" leaves the choice to the plot default, and its title says what that
/// default is, such as "Default (Opus)".
struct ModelEffortPickers: View {
    @Binding var model: String
    @Binding var effort: String
    let defaults: RunDefaults?
    /// The start of the accessibility IDs, such as "intake".
    let id: String
    /// The help of each picker.
    var help = "The model and the effort of the session of the run. Default is the plot default, else that of Claude Code."

    var body: some View {
        HStack(alignment: .top, spacing: LoamTheme.space3) {
            picker("Model", $model, RunChoices.models, defaultValue: defaults?.model, id: "\(id)-model")
            picker("Effort", $effort, RunChoices.efforts, defaultValue: defaults?.effort, id: "\(id)-effort")
        }
    }

    private func picker(_ label: String, _ value: Binding<String>, _ choices: [RunChoices.Choice], defaultValue: String?,
                        id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            Picker(label, selection: value) {
                ForEach(choices) { choice in
                    Text(choice.value.isEmpty ? RunChoices.defaultTitle(defaultValue, in: choices) : choice.title).tag(choice.value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(help)
            .accessibilityIdentifier(id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
