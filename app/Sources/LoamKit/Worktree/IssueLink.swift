import Foundation

/// A link to one issue in Linear or GitHub (ticket 115). Start work… is offered only for such a link: the core
/// refuses any other URL for `--link`. A GitHub pull request is not an issue, and neither is a Linear project.
/// The rules are those of `linkkind.IssueKey` in the core (`core/internal/linkkind/issuekey.go`), without the repo of
/// origin: the core works out the key that the PR body needs. This type decides only whether to offer the action, and
/// what the branch name starts with.
public struct IssueLink: Equatable, Sendable {
    public enum Service: Equatable, Sendable {
        case linear
        case github
    }

    public let service: Service
    /// The issue ID for Linear, in capitals ("ENG-482"). The issue number for GitHub ("57").
    public let id: String

    /// The service that the session reads the issue through: "Linear" or "GitHub".
    public var connector: String {
        switch service {
        case .linear: "Linear"
        case .github: "GitHub"
        }
    }

    public init?(target: String) {
        let text = target.trimmingCharacters(in: .whitespacesAndNewlines)
        // A local path has no host. `URL(string:)` takes "~/x" as a relative URL.
        guard !text.hasPrefix("/"), !text.hasPrefix("~"), let url = URL(string: text), let host = url.host()?.lowercased()
        else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        switch host.hasPrefix("www.") ? String(host.dropFirst(4)) : host {
        case "linear.app":
            guard parts.count >= 3, parts[1] == "issue", Self.isLinearID(parts[2]) else { return nil }
            self.init(service: .linear, id: parts[2].uppercased())
        case "github.com":
            guard parts.count >= 4, parts[2] == "issues", Self.isDigits(parts[3]),
                  Self.isGitHubName(parts[0]), Self.isGitHubName(parts[1]) else { return nil }
            self.init(service: .github, id: parts[3])
        default:
            return nil
        }
    }

    private init(service: Service, id: String) {
        self.service = service
        self.id = id
    }

    /// The shape of a Linear issue ID: letters and digits, a hyphen, and digits ("ENG-482").
    private static func isLinearID(_ text: String) -> Bool {
        let halves = text.split(separator: "-", omittingEmptySubsequences: false)
        guard halves.count == 2, let first = halves[0].first, first.isASCII, first.isLetter else { return false }
        return halves[0].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && isDigits(String(halves[1]))
    }

    private static func isDigits(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// A GitHub owner or repo name: letters, digits, dots, hyphens, and underscores.
    private static func isGitHubName(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }
}

extension IssueLink {
    /// The issue that a link of this kind and target points at. Nil for a link of any other kind than Linear and GitHub.
    public init?(kind: LinkKind, target: String) {
        switch kind {
        case .linear, .github: self.init(target: target)
        case .notion, .url, .path, .vault: return nil
        }
    }
}

extension PlotLink {
    /// The issue that the link points at, for Start work… (ticket 115). Nil for a link of any other kind, and for a GitHub pull
    /// request.
    public var issue: IssueLink? { IssueLink(kind: kind, target: target) }
}
