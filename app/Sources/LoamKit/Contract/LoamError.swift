import Foundation

/// Every way a `loam` call fails. The exit code picks the case. The message is for a person to read.
public enum LoamError: Error, Equatable, Sendable {
    /// Exit 1.
    case failed(message: String)
    /// Exit 2: bad flag, argument, or value.
    case invalid(message: String)
    /// Exit 10: a write used an out-of-date version. Nothing was written.
    case stale(StaleDetails?, message: String)
    /// Exit 11: an undo meets a later change to the same item.
    case undoClash(UndoClashDetails?, message: String)
    /// Exit 12: a local link points at a missing path.
    case linkPathMissing(LinkPathMissingDetails?, message: String)
    /// Exit 13: the core reports a contract mismatch.
    case contractMismatch(message: String)
    /// Exit 14.
    case unknownPlot(message: String)
    /// Exit 15.
    case ambiguous(message: String)
    /// An exit code that this app does not know.
    case unknown(exitCode: Int32, message: String)

    // Errors that have no exit code.

    /// The binary is not at the path.
    case binaryMissing(path: String)
    /// The process did not start.
    case launchFailed(String)
    /// Exit 0, but the output is not the expected JSON.
    case undecodable(String)
    /// The app and the core read different contract versions.
    case contractVersionMismatch(core: Int, app: Int)

    /// Maps an exit code of the contract table (docs/contract.md) to a case.
    static func from(exitCode: Int32, message: String, details: Data?) -> LoamError {
        func decode<T: Decodable>(_ type: T.Type) -> T? {
            details.flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        switch exitCode {
        case 1: return .failed(message: message)
        case 2: return .invalid(message: message)
        case 10: return .stale(decode(StaleDetails.self), message: message)
        case 11: return .undoClash(decode(UndoClashDetails.self), message: message)
        case 12: return .linkPathMissing(decode(LinkPathMissingDetails.self), message: message)
        case 13: return .contractMismatch(message: message)
        case 14: return .unknownPlot(message: message)
        case 15: return .ambiguous(message: message)
        default: return .unknown(exitCode: exitCode, message: message)
        }
    }

    /// Text for the blocking screen or an alert.
    public var userMessage: String {
        switch self {
        case .failed(let m), .invalid(let m), .contractMismatch(let m),
             .unknownPlot(let m), .linkPathMissing(_, let m), .ambiguous(let m), .stale(_, let m), .undoClash(_, let m),
             .unknown(_, let m):
            return m
        case .binaryMissing(let path):
            return "The loam command is not at \(path). Run the install script."
        case .launchFailed(let m):
            return "The loam command did not start: \(m)"
        case .undecodable(let m):
            return "The loam command printed output that the app cannot read: \(m)"
        case .contractVersionMismatch(let core, let app):
            if core > app {
                return "The loam command is newer than this app (contract \(core), app reads \(app)). Update the app."
            }
            return "The loam command is older than this app (contract \(core), app reads \(app)). Update the loam command."
        }
    }
}
