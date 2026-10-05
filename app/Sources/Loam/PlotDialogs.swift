import AppKit
import LoamKit

/// The sheets of the plot lifecycle actions (spec section 10). The decisions live in `AppModel`.
@MainActor
enum PlotDialogs {
    /// Archive. It asks first when a session in the plot asks (`ClosePrompt`), else it goes ahead.
    static func askArchive(_ plot: String, model: AppModel) {
        guard let prompt = model.archivePrompt(for: plot) else {
            Task { @MainActor in await model.archivePlot(plot) }
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }  // No window: ask nothing and archive nothing.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: prompt.confirm)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in await model.archivePlot(plot) }
        }
    }

    /// Delete. It cannot be undone, so it always asks. Cancel is the first button, so Return never deletes.
    static func askDelete(_ plot: PlotSummary, model: AppModel) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete \u{201C}\(plot.name)\u{201D}?"
        alert.informativeText = "Loam removes the plot, its change log, and its session records for good. "
            + "There is no undo. Loam moves the plot folder to the Trash. "
            + "Claude Code's own files for the plot stay where they are."
        alert.addButton(withTitle: "Cancel")
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            Task { @MainActor in
                guard let result = await model.deletePlot(plot.id) else { return }
                showDeleted(result)
            }
        }
    }

    /// The text of the notice after a delete: where the plot folder went, and which Claude Code
    /// folders Loam left alone.
    static func deletedMessage(_ result: DeleteResult) -> String {
        var lines: [String] = []
        lines.append(result.trash.isEmpty ? "The plot had no folder." : "The plot folder is in the Trash: \(result.trash)")
        if result.claudeFiles.isEmpty {
            lines.append("Claude Code has no files for this plot.")
        } else {
            lines.append("Loam left Claude Code's files for this plot. Remove them yourself if you want:")
            lines.append(contentsOf: result.claudeFiles)
        }
        return lines.joined(separator: "\n")
    }

    private static func showDeleted(_ result: DeleteResult) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Deleted \u{201C}\(result.name)\u{201D}"
        alert.informativeText = deletedMessage(result)
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }
}
