import Foundation

/// The decision at launch: block on a contract mismatch, otherwise carry the pending setup steps.
public enum LaunchCheck: Equatable, Sendable {
    case blocked(message: String)
    case ready(pendingSteps: [SetupStep])

    public static func run(client: LoamClient) async -> LaunchCheck {
        do {
            try await client.checkContract()
        } catch {
            return .blocked(message: (error as? LoamError)?.userMessage ?? String(describing: error))
        }
        // The setup banner never blocks. A failed check shows no banner.
        guard let setup = try? await client.setupCheck(), setup.needsBanner else {
            return .ready(pendingSteps: [])
        }
        return .ready(pendingSteps: setup.pendingSteps)
    }
}
