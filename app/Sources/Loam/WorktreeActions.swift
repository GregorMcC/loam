import AppKit
import LoamKit
import SwiftUI

/// The actions of one worktree, built once for the hover menu and the context menu of the panel row and
/// for the context menu of the sidebar row (ticket 108). Tickets 110 and 112 add Send failures to
/// session and Land here.
struct WorktreeActions: View {
    let model: AppModel
    let id: String

    var body: some View {
        let status = model.worktreeStatus(id)
        Button("Open on GitHub") { open(status?.pullRequestPage) }
            .disabled(status?.pullRequestPage == nil)
        Button("Copy branch name") { copy(status?.worktree.branch) }
        Button("Refresh") {
            if let plot = status?.worktree.plotID { Task { await model.shipRefresh.refresh(plot) } }
        }
        Divider()
        Button("Remove\u{2026}") { WorktreeDialogs.askRemove(id, model: model) }
    }

    private func open(_ page: URL?) {
        guard let page else { return }
        NSWorkspace.shared.open(page)
    }

    private func copy(_ branch: String?) {
        guard let branch else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(branch, forType: .string)
    }
}
