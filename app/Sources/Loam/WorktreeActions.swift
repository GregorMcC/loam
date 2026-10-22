import AppKit
import LoamKit
import SwiftUI

/// The actions of one worktree, built once for the hover menu and the context menu of the panel row and
/// for the context menu of the sidebar row (ticket 108). Tickets 110 and 112 add Send failures to
/// session and Land here. Open on GitHub opens the PR in the browser. The PR popover has the details.
struct WorktreeActions: View {
    let model: AppModel
    let id: String

    var body: some View {
        let status = model.worktreeStatus(id)
        Button("Open on GitHub") {
            if let page = status?.pullRequestPage { SystemActions.open(page) }
        }
        .disabled(status?.pullRequestPage == nil)
        Button("Copy branch name") {
            if let branch = status?.worktree.branch { SystemActions.copy(branch) }
        }
        Button("Refresh") {
            if let plot = status?.worktree.plotID { Task { await model.shipRefresh.refresh(plot) } }
        }
        Divider()
        Button("Remove\u{2026}") { WorktreeDialogs.askRemove(id, model: model) }
    }
}

/// The two things that a worktree menu and the PR popover do outside the app: open an address in the
/// browser, and copy text.
enum SystemActions {
    static func open(_ page: URL) {
        NSWorkspace.shared.open(page)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
