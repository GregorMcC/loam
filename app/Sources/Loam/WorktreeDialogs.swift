import AppKit
import LoamKit

/// The sheets of the worktree actions. The decisions live in `AppModel` and `WorktreeRules`.
@MainActor
enum WorktreeDialogs {
    /// "New worktree": asks for a name. The name is the branch name, as the core takes it.
    static func askNewWorktree(plot: String, model: AppModel) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Branch name"
        let alert = NSAlert()
        alert.messageText = "New worktree"
        alert.informativeText = "Name the branch. Loam makes a worktree of the main repo and starts a session in it."
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue
            Task { @MainActor in await model.newWorktree(in: plot, named: name) }
        }
    }

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
