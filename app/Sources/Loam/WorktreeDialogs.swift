import AppKit
import LoamKit

/// The sheets of the worktree actions. The decisions live in `AppModel` and `WorktreeRules`.
@MainActor
enum WorktreeDialogs {
    /// "Remove": the checks first. A refusal is only a message. An unsafe worktree asks again
    /// with a Remove Anyway button.
    static func askRemove(_ id: String, model: AppModel) {
        Task { @MainActor in
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
                  let plan = await model.planRemoval(of: id),
                  let worktree = model.worktreeStatus(id)?.worktree else { return }
            let alert = NSAlert()
            alert.messageText = plan.needsConfirmation ? "Remove worktree" : "Cannot remove the worktree"
            alert.informativeText = plan.message(for: worktree)
            var force = false
            switch plan {
            case .refusedOpenPanes:
                alert.addButton(withTitle: "OK")
            case .needsForce:
                force = true
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Remove Anyway")
            case .ready:
                alert.addButton(withTitle: "Remove")
                alert.addButton(withTitle: "Cancel")
            }
            guard plan.needsConfirmation else {
                alert.beginSheetModal(for: window) { _ in }
                return
            }
            // Cancel is the first button of the forced removal, so Return never forces it.
            let yes: NSApplication.ModalResponse = force ? .alertSecondButtonReturn : .alertFirstButtonReturn
            alert.beginSheetModal(for: window) { response in
                guard response == yes else { return }
                Task { @MainActor in await model.removeWorktree(id, force: force) }
            }
        }
    }
}
