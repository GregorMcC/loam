import AppKit
import LoamKit
import SwiftUI

/// The actions of one worktree, built once for the hover menu and the context menu of the panel row and
/// for the context menu of the sidebar row (ticket 108). Send failures to session shows only when the checks
/// failed (ticket 110), and ticket 112 adds Land here. Open on GitHub opens the PR in the browser, or the
/// compare page of a branch that is pushed and has no PR, as the PR popover does. The PR popover has the details.
struct WorktreeActions: View {
    let model: AppModel
    let id: String

    var body: some View {
        let status = model.worktreeStatus(id)
        if model.canSendFailures(id) {
            Button(PRPrimaryAction.sendFailures.title) { model.sendFromMenu(id) }
            Divider()
        }
        Button("Open on GitHub") {
            if let page = status?.githubPage { SystemActions.open(page) }
        }
        .disabled(status?.githubPage == nil)
        Button("Copy branch name") {
            if let branch = status?.worktree.branch { model.copyText(branch) }
        }
        Button("Refresh") {
            if let plot = status?.worktree.plotID { Task { await model.shipRefresh.refresh(plot) } }
        }
        Divider()
        Button("Remove\u{2026}") { WorktreeDialogs.askRemove(id, model: model) }
    }
}

/// The two things that a worktree menu and the PR popover do outside the app: open an address in the
/// browser, and copy text. The window copies through `AppModel.copyText`, which the driver points at a private
/// pasteboard.
enum SystemActions {
    static func open(_ page: URL) {
        NSWorkspace.shared.open(page)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
