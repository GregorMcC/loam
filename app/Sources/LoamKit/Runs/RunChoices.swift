import Foundation

/// The models and the effort levels that a run can name, for the pickers. The first choice of each is "",
/// which leaves the choice to the plot default, then to Claude Code.
public enum RunChoices {
    public struct Choice: Equatable, Sendable, Identifiable {
        public var value: String
        public var title: String
        public var id: String { value }
    }

    /// The model aliases of Claude Code.
    public static let models = [Choice(value: "", title: "Default")] +
        [("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")].map { Choice(value: $0.0, title: $0.1) }

    /// The `--effort` levels of Claude Code.
    public static let efforts = [Choice(value: "", title: "Default")] +
        [("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra high"), ("max", "Max")]
            .map { Choice(value: $0.0, title: $0.1) }

    /// The value of the Repo choice that has Claude split the issue across the repos of the plot (TAS-37).
    public static let split = "split"

    /// The choices of the Repo picker: each repo of the plot by its folder name, the main repo first. With two
    /// repos or more, the last choice has Claude split the issue across them.
    public static func repos(_ checkouts: [RepoCheckout]) -> [Choice] {
        let ordered = checkouts.filter(\.isMain) + checkouts.filter { !$0.isMain }
        let repos = ordered.map { Choice(value: $0.id, title: URL(fileURLWithPath: $0.path).lastPathComponent) }
        return repos.count < 2 ? repos : repos + [Choice(value: split, title: "Claude splits it across the repos")]
    }

    /// The title of the "" choice, which says what the default is: the plot default, or Claude Code's.
    public static func defaultTitle(_ value: String?, in choices: [Choice]) -> String {
        guard let value, !value.isEmpty else { return "Default" }
        return "Default (\(choices.first { $0.value == value }?.title ?? value))"
    }
}
