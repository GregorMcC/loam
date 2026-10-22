import Foundation

/// What the PR popover says after Re-run failed or Update branch (ticket 109), from the answer of the
/// core. Simplified Technical English. A refusal of GitHub comes in the words of the core.
public enum PRActionNote {
    /// "GitHub runs the failed checks of 2 runs again." Then the reason for each run that GitHub did not
    /// start, and the failed checks that are not jobs of GitHub Actions.
    public static func rerun(_ result: RerunResult) -> String {
        let started = result.runs.filter(\.started).count
        var sentences = [started == 0 ? "GitHub did not run any check again."
                                      : "GitHub runs the failed checks of \(started) \(started == 1 ? "run" : "runs") again."]
        for run in result.runs where !run.started {
            sentences.append(sentence(run.note) ?? "GitHub did not start the run \(run.id).")
        }
        if !result.skippedChecks.isEmpty {
            sentences.append("Loam cannot run these failed checks again: \(result.skippedChecks.joined(separator: ", ")).")
        }
        return sentences.joined(separator: " ")
    }

    /// "GitHub brought the PR up to date with main." When the fetch failed, it adds why.
    public static func update(_ result: UpdateResult) -> String {
        let first = "GitHub brought the PR up to date with \(result.pr.base)."
        guard !result.fetched else { return first }
        let why = result.fetchNote.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? "."
        return first + " Loam could not fetch the new commits" + why
    }

    /// The text of the core as a sentence: it starts with a capital letter. Nil for no text.
    private static func sentence(_ text: String?) -> String? {
        guard let text, let first = text.first else { return nil }
        return first.uppercased() + text.dropFirst()
    }
}
