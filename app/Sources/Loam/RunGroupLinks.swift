import LoamKit
import SwiftUI

/// The other runs that Shape split from the same issue, one for each repo (TAS-37). A click opens a run: at the desk
/// when it waits there, else on its page.
struct RunGroupLinks: View {
    let model: AppModel
    let run: Run

    var body: some View {
        let others = model.groupRuns(of: run)
        if !others.isEmpty {
            HStack(spacing: 6) {
                Text("Split with").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                ForEach(others) { other in
                    Button { open(other) } label: {
                        Text(words(other)).loamText(LoamTheme.captionStyle, LoamColor.ink).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(LoamColor.inkSelected))
                    }
                    .buttonStyle(.plain)
                    .help(other.title)
                    .accessibilityIdentifier("run-group-\(other.id)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("run-group")
        }
    }

    private func words(_ other: Run) -> String {
        let repo = model.repoName(of: other)
        return "\(repo.isEmpty ? other.title : repo) \u{00B7} \(other.state.words)"
    }

    private func open(_ other: Run) {
        Task {
            if other.state == .shaping || other.state == .ready {
                await model.openDesk(other.id)
            } else {
                await model.openRun(other.id)
            }
        }
    }
}
