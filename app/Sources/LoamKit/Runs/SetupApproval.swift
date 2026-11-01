import CryptoKit
import Foundation

/// The hash that names a setup command in `--approve-setup`: the lowercase hex SHA-256 of its exact text. The app
/// computes it from the text that a page shows, so the core refuses when the repo holds another command by then.
public func setupHash(_ command: String) -> String {
    SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// The setup command that the Intake page shows with a refused start, and the repo that holds it. An approval on the
/// page approves this command for the drafts of this repo, and for no other repo.
public struct ShownSetup: Equatable, Sendable {
    /// The ID of the repo.
    public var repo: String
    /// True when the repo is the main repo of the plot, which a draft with no repo starts on.
    public var isMain: Bool
    public var command: String

    public init(repo: String, isMain: Bool, command: String) {
        self.repo = repo
        self.isMain = isMain
        self.command = command
    }

    /// The value of `--approve-setup` for a draft of the repo with the ID, or of the main repo for nil. A draft of
    /// another repo gets none, so that draft stops with its own approval error.
    public func hash(forRepo repo: String?) -> String? {
        (repo.map { $0 == self.repo } ?? isMain) ? setupHash(command) : nil
    }
}
