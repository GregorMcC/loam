import Foundation

/// The alert state of a pane (spec 8.4). `Workspace.attention(of:)` gives it.
/// Done, unread comes back after a restart. Needs you does not.
public enum PaneAttention: String, Codable, Equatable, Sendable {
    case none
    case needsYou
    case doneUnread
}

/// The keys that count as typing in a pane (spec 8.4). A key that sends text, Return, Escape, or
/// Delete answers the prompt, so needs you clears. A key that only moves (an arrow key, Tab, Page Up,
/// or a function key) does not, because Claude Code's prompts use these keys to pick an option.
public enum TypingKey {
    /// `characters` is the key event's text, as `NSEvent.characters` gives it.
    public static func clearsNeedsYou(_ characters: String?) -> Bool {
        guard let scalar = characters?.unicodeScalars.first else { return false }
        if (0xF700...0xF8FF).contains(scalar.value) { return false }  // AppKit's arrow and function keys.
        return scalar != "\t" && scalar.value != 0x19  // Tab and Shift-Tab.
    }
}

/// A macOS banner for a pane that needs you (spec 8.4). The app shows one only while another app
/// is frontmost. A click on it focuses the pane.
public struct AttentionBanner: Equatable, Sendable {
    public var pane: PaneID
    public var title: String
    public var subtitle: String
    public var body: String

    public init(pane: PaneID, title: String, subtitle: String, body: String) {
        self.pane = pane
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    /// The banner for a pane of `plotName` with the title `paneTitle` that waits on `reason`.
    public init(pane: PaneID, plotName: String, paneTitle: String, reason: NeedsYouReason?) {
        let body = switch reason {
        case .permission: "Claude asks for permission."
        case .question: "Claude asks you a question."
        case .input: "Claude needs your input."
        case .apiError: "The turn stopped on an API error."
        case nil: "The session waits for you."
        }
        self.init(pane: pane, title: "Needs you in \(plotName)", subtitle: paneTitle, body: body)
    }
}

/// What tells you outside the app that a pane needs you: the macOS banner and the Dock badge.
/// The app uses the system one. Tests and the driver use a fake, so no real banner or permission
/// prompt shows.
@MainActor
public protocol AttentionNotifier: AnyObject {
    /// Shows a banner for a pane that started to need you. The first banner asks for permission.
    func post(_ banner: AttentionBanner)
    /// Removes the banners of panes that no longer need you.
    func remove(_ panes: [PaneID])
    /// Sets the Dock badge to the number of panes that need you. 0 removes the badge.
    func setBadge(_ count: Int)
}

/// A notifier that keeps what it was asked to do. The driver uses it.
@MainActor
public final class RecordingNotifier: AttentionNotifier {
    public private(set) var banners: [AttentionBanner] = []
    public private(set) var removed: [PaneID] = []
    public private(set) var badge = 0

    public init() {}

    public func post(_ banner: AttentionBanner) { banners.append(banner) }
    public func remove(_ panes: [PaneID]) { removed += panes }
    public func setBadge(_ count: Int) { badge = count }
}
