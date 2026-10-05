import Foundation
import Observation

extension Change {
    /// True when the change edits a repo of the plot. Repo items are `repo:<id>` in the log.
    public var touchesRepos: Bool { entries.contains { $0.item.hasPrefix("repo:") } }
}

/// An undo that met a later change to the same items (exit code 11). The panel shows it with
/// Cancel and "Undo and overwrite".
public struct UndoClashPrompt: Equatable, Sendable {
    public var changeID: Int
    /// The later changes that touched the same items, oldest first.
    public var laterChanges: [Change]
    /// What the undo writes. `old` is the current value and `new` is what the undo sets.
    public var undoWouldWrite: [ChangeEntry]
}

/// Review and undo (spec 8.6): the change log, the "New since you looked" box, the counts, and undo.
/// The log comes from `loam changes`. The last-seen change IDs live in `state.json`.
@MainActor
@Observable
public final class ReviewModel {
    @ObservationIgnored public let client: LoamClient
    @ObservationIgnored public let state: AppStateFile
    @ObservationIgnored public var timeZone: TimeZone = .current

    /// Every change of every plot, oldest first.
    public private(set) var changes: [Change] = []
    /// The last-seen change ID of each plot.
    public private(set) var lastSeen: [String: Int] = [:]
    /// The count of new changes for each plot. A plot with none is not in it. It is counted when
    /// the log or `lastSeen` changes, not on each read: the sidebar reads it on every rebuild.
    public private(set) var newCounts: [String: Int] = [:]
    public private(set) var clash: UndoClashPrompt?
    public var errorMessage: String?

    /// Maps a session ID to the pane that runs it. The app sets it when panes that run sessions exist (tickets 25 to 28).
    /// Until then it is nil, and a session that Loam started shows without a pane name.
    @ObservationIgnored public var paneLookup: (@MainActor (String) -> PaneRef?)?
    /// Called when a person clicks a pane name. The app wires it to focus the pane.
    @ObservationIgnored public var onGoToPane: (@MainActor (PaneRef) -> Void)?
    /// Called after an undo wrote a change, so the app can reload the plot.
    @ObservationIgnored public var onUndone: (@MainActor () async -> Void)?

    @ObservationIgnored private var loaded = false

    public init(client: LoamClient, state: AppStateFile = AppStateFile()) {
        self.client = client
        self.state = state
    }

    // MARK: Reading

    /// Reads the log. The first read reads all of it. Later reads read what is above the highest ID.
    /// With no `last_seen_changes` in `state.json` (a first run), every plot counts as seen up to now,
    /// so the first launch does not list the whole history as new. A failed read keeps what is shown.
    public func reload() async {
        do {
            let fresh = try await client.changes(since: loaded ? changes.last?.id : nil)
            errorMessage = nil
            let known = Set(changes.map(\.id))
            changes += fresh.filter { !known.contains($0.id) }
            changes.sort { $0.id < $1.id }
            if !loaded {
                loaded = true
                if let stored = state.lastSeenChanges() {
                    lastSeen = stored
                } else {
                    var baseline: [String: Int] = [:]
                    for change in changes { baseline[change.plotID] = max(baseline[change.plotID] ?? 0, change.id) }
                    lastSeen = baseline
                    persist()
                }
            }
            newCounts = ChangeRules.newCounts(in: changes, lastSeen: lastSeen)
        } catch {
            errorMessage = (error as? LoamError)?.userMessage ?? String(describing: error)
        }
    }

    // MARK: What the views show

    public func newChanges(plot: String) -> [Change] {
        ChangeRules.newChanges(in: changes, plot: plot, lastSeen: lastSeen[plot] ?? 0)
    }

    public func log(plot: String) -> [Change] { ChangeRules.log(in: changes, plot: plot) }



    public func newCount(plot: String?) -> Int { plot.flatMap { newCounts[$0] } ?? 0 }

    /// The newest change to a repo (an add, a removal, a new main repo, or an undo of one). The
    /// sidebar reads the main checkouts again when it moves (ticket 71).
    public var lastRepoChangeID: Int? { changes.last(where: \.touchesRepos)?.id }

    /// The counts for the sidebar: every plot except the active one.
    public func sidebarCounts(activePlot: String?) -> [String: Int] {
        newCounts.filter { $0.key != activePlot }
    }

    public func actorLabel(_ change: Change) -> ActorLabel {
        let pane = change.actor.sessionID.flatMap { paneLookup?($0) }
        return ActorLabel.make(change.actor, pane: pane)
    }

    public func goToPane(of label: ActorLabel) {
        if let pane = label.pane { onGoToPane?(pane) }
    }

    public func clock(_ change: Change) -> String { ChangeRules.clock(change.at, timeZone: timeZone) }

    /// "undone HH:MM" when a later change undid this one. Nil otherwise.
    public func undoneNote(_ change: Change) -> String? {
        ChangeRules.undoingChange(of: change, in: changes).map { "undone \(clock($0))" }
    }

    // MARK: Seen

    /// Marks every change of `plot` as seen. The panel calls it on close, and on a plot switch with the panel open.
    public func markSeen(plot: String?) {
        guard let plot, let newest = ChangeRules.newestID(in: changes, plot: plot) else { return }
        guard newest > (lastSeen[plot] ?? 0) else { return }
        lastSeen[plot] = newest
        newCounts = ChangeRules.newCounts(in: changes, lastSeen: lastSeen)
        persist()
    }

    private func persist() {
        do { try state.setLastSeenChanges(lastSeen) } catch {
            errorMessage = "The app could not save which changes you have seen."
        }
    }

    // MARK: Undo

    /// `loam undo <id> --json`. A clash sets `clash` and writes nothing.
    public func undo(_ change: Change) async {
        await runUndo(change.id, overwrite: false)
    }

    /// "Undo and overwrite" in the clash prompt.
    public func confirmOverwrite() async {
        guard let id = clash?.changeID else { return }
        await runUndo(id, overwrite: true)
    }

    public func cancelClash() { clash = nil }

    private func runUndo(_ id: Int, overwrite: Bool) async {
        do {
            _ = try await client.undo(changeID: id, overwrite: overwrite)
            clash = nil
            errorMessage = nil
            await reload()
            await onUndone?()
        } catch LoamError.undoClash(let details, let message) {
            if let details {
                clash = UndoClashPrompt(
                    changeID: id, laterChanges: details.laterChanges, undoWouldWrite: details.undoWouldWrite)
                errorMessage = nil
            } else {
                clash = nil
                errorMessage = message
            }
        } catch {
            clash = nil
            errorMessage = (error as? LoamError)?.userMessage ?? String(describing: error)
        }
    }
}
