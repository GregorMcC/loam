import Foundation
import Observation

/// What the settings window shows about the Ghostty config: the files that the last load read and
/// its errors. The terminal runtime fills it after each load, and sets the two actions.
@MainActor
@Observable
public final class TerminalConfigModel {
    public var files: [String] = []
    public var errors: [String] = []
    /// False when the app has no terminal runtime, or no config file to open.
    public var canOpen = false
    @ObservationIgnored public var open: @MainActor () -> Void = {}
    @ObservationIgnored public var reload: @MainActor () -> Void = {}

    public init() {}
}
