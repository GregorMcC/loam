import Foundation

/// A merge that a refresh found: a worktree and the number of its PR that GitHub merged (ticket 113).
public struct MergedPR: Hashable, Sendable, Identifiable {
    public var worktree: String
    public var number: Int
    public var id: String { worktree }

    public init(worktree: String, number: Int) {
        self.worktree = worktree
        self.number = number
    }
}

/// What the app does when a refresh finds that GitHub merged the PR of a worktree (ticket 113). Removing a worktree
/// can lose work, so the rules here say no in each case they are not sure about.
public enum AfterMergeRule {
    /// What a merged PR gets.
    public enum Action: Equatable, Sendable {
        /// Tidy up as the land that ticket 111 recorded says: `loam worktree land` with no flags.
        case tidy(PendingLand)
        /// Follow the repo setting.
        case follow
    }

    /// The merge of a row, or nil. Only a row at the Merged stage whose PR state is MERGED counts, only while its
    /// folder is there, and only when the last refresh got an answer from GitHub. A refresh with no answer (offline,
    /// rate limited, no access) gives the PR from the cache, with a note. The core checks for work after the PR head
    /// before it gives the Merged stage, but a cache row from before Loam kept the PR head gets the Merged stage with no
    /// such check. So the app checks the work of the row itself (`holdsNoWork`).
    public static func merge(of row: WorktreeStatus) -> MergedPR? {
        guard row.stage == .merged, !row.missing, (row.prNote ?? .noNote) == .noNote, let pr = row.pr, pr.state == "MERGED"
        else { return nil }
        return MergedPR(worktree: row.worktree.id, number: pr.number)
    }

    /// A land that the worktree records applies only to the PR it names. A land of another PR is stale: its keeps
    /// do not apply, and the repo setting decides.
    public static func action(for merge: MergedPR, land: PendingLand?) -> Action {
        guard let land, land.pr == merge.number else { return .follow }
        return .tidy(land)
    }

    /// True when the app knows of no work in the worktree that is not on GitHub: git found no changed files and no
    /// commit that no remote branch holds, and no check failed.
    public static func holdsNoWork(_ row: WorktreeStatus) -> Bool {
        row.changed == 0 && row.unpushed == 0 && row.error == nil && !row.missing
    }

    /// True when Loam can close the pane with no question and stop nothing: a session that is not mid-turn and does
    /// not need you, or a shell that runs no process, such as a dev server. `runsAProcess` reads the terminal.
    public static func closesQuietly(_ pane: PaneID, in workspace: Workspace, runsAProcess: (PaneID) -> Bool) -> Bool {
        workspace.spec(of: pane)?.kind == .shell ? !runsAProcess(pane) : !ClosePrompt.asks(for: pane, in: workspace)
    }

    /// True when Loam can remove the worktree with no question: it holds no work, and each of its panes closes quietly.
    public static func canRemove(_ row: WorktreeStatus, panes: [PaneID], in workspace: Workspace,
                                 runsAProcess: (PaneID) -> Bool) -> Bool {
        holdsNoWork(row) && panes.allSatisfy { closesQuietly($0, in: workspace, runsAProcess: runsAProcess) }
    }

    // MARK: Words

    /// The name of the submenu in the Repo actions menu of a Repos row.
    public static let menuTitle = "After a merge on GitHub"

    /// The radio item of a setting in the submenu.
    public static func title(_ setting: AfterMerge) -> String {
        switch setting {
        case .ask: "Ask"
        case .remove: "Remove the worktree"
        case .keep: "Do nothing"
        }
    }

    /// The Ask callout: "#142 was merged on GitHub. Remove the worktree link-labels?"
    public static func question(_ merge: MergedPR, name: String) -> String {
        "\(StageMark.numberText(merge.number)) was merged on GitHub. Remove the worktree \(name)?"
    }

    /// The toast after Remove the worktree: "#142 was merged on GitHub. Loam removed the worktree link-labels."
    public static func removed(_ merge: MergedPR, name: String) -> String {
        "\(StageMark.numberText(merge.number)) was merged on GitHub. Loam removed the worktree \(name)."
    }

    /// The words of a `loam` call that failed for the worktree, for the panel. The app has no flags such as `--force`,
    /// so the words never name one. A refused `loam worktree rm` gets the words of the Remove worktree dialog. Another
    /// error shows its message without each sentence that names a flag.
    public static func refusal(_ error: Error, for worktree: Worktree) -> String {
        if case .refusedRemoval(let details, _) = error as? LoamError {
            let plan: WorktreeRemovalPlan = switch details.refusal {
            case .unsafeWork:
                .needsForce(changed: details.changed ?? 0, unpushed: details.unpushed ?? 0, checkError: details.checkError)
            case .openPanes: .refusedOpenPanes(open: details.openPanes ?? 0, saved: 0)
            }
            let text = plan.message(for: worktree)
            if !text.isEmpty { return text }
        }
        let message = (error as? LoamError)?.userMessage ?? String(describing: error)
        let kept = message.components(separatedBy: ". ").filter { $0.range(of: "--[a-z]", options: .regularExpression) == nil }
        guard !kept.isEmpty else { return "Loam could not finish the step for the worktree \(worktree.name)." }
        let text = kept.joined(separator: ". ")
        return text.hasSuffix(".") ? text : text + "."
    }
}

/// The merges that you chose to keep, by worktree, with the PR number. A worktree that you kept shows the faded Merged
/// row with its Remove… pill and no callout. A new PR of the same worktree asks again. They live in `state.json` under
/// `kept_merges`, through the app's one `AppStateWriter`. With no writer (tests), they live in memory only.
@MainActor
public final class KeptMerges {
    public static let key = "kept_merges"

    private let writer: AppStateWriter?
    private var kept: [String: Int]

    public init(writer: AppStateWriter? = nil) {
        self.writer = writer
        let raw = writer?.file.value(forKey: Self.key) as? [String: Any] ?? [:]
        kept = raw.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    public func contains(_ merge: MergedPR) -> Bool { kept[merge.worktree] == merge.number }

    public func keep(_ merge: MergedPR) {
        guard kept[merge.worktree] != merge.number else { return }
        kept[merge.worktree] = merge.number
        save()
    }

    /// Drops the worktrees that are gone. Call it with the full list of worktrees only.
    public func prune(keeping worktrees: Set<String>) {
        let next = kept.filter { worktrees.contains($0.key) }
        guard next.count != kept.count else { return }
        kept = next
        save()
    }

    private func save() {
        writer?.setChanged(Self.key) { [self] in kept }
    }
}
