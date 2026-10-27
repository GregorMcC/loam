import Foundation

/// The bases that a run can start from, for the Base picker of the start form (TAS-21): the branches of the main repo
/// of the plot, as `loam worktree new --dry-run` lists them. With no base, the core starts a run from the default
/// branch of origin. A repo with no origin has no such branch, so the picker starts on the branch of the main
/// checkout, and the run gets it as its base.
public struct RunBases: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var title: String
        /// The base for `--base`, or nil for the default branch of origin.
        public var value: String?
    }

    public var plot: String
    /// The first item is the base that the form starts on.
    public var items: [Item]
    /// The base that the form starts on. Nil is the default branch of origin.
    public var first: String?

    public init(plot: String, check: WorktreeCheck, branch: String?) {
        self.plot = plot
        if !check.defaultBase.isEmpty {
            items = [Item(title: check.defaultBase, value: nil)]
                + check.bases.filter { $0 != check.defaultBase }.map { Item(title: $0, value: $0) }
            first = nil
        } else if check.bases.contains(where: { $0.hasPrefix("origin/") }) {
            items = [Item(title: NewWorktreeContent.originDefault, value: nil)] + check.bases.map { Item(title: $0, value: $0) }
            first = nil
        } else {
            let start = branch.flatMap { check.bases.contains($0) ? $0 : nil } ?? check.bases.first
            let ordered = start.map { start in [start] + check.bases.filter { $0 != start } } ?? []
            items = ordered.map { Item(title: $0, value: $0) }
            first = start
        }
    }
}
