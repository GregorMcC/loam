import AppKit
import LoamKit
import OSLog
import UserNotifications

/// The macOS banner and the Dock badge for panes that need you (spec 8.4). `AppModel` posts a
/// banner only while another app is frontmost. The first banner asks for permission, not the
/// launch. A click on a banner calls `onOpen`, which brings Loam to the front and focuses the pane.
///
/// A banner needs an app bundle, so a debug binary outside `Loam.app` sets only the Dock badge.
/// The driver and the tests never make this notifier; they use `RecordingNotifier`.
@MainActor
final class SystemAttentionNotifier: NSObject, AttentionNotifier, UNUserNotificationCenterDelegate {
    var onOpen: ((PaneID) -> Void)?
    private let center: UNUserNotificationCenter?

    override init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self
    }

    func post(_ banner: AttentionBanner) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.subtitle = banner.subtitle
        content.body = banner.body
        content.threadIdentifier = "needs-you"
        // The pane ID is the request ID, so `remove` can take the banner away and a click finds the pane.
        let id = banner.pane.uuidString
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        posted.insert(id)
        Task {
            // Needs you can clear while the permission question shows. Then no banner goes up.
            guard await authorized(center), posted.contains(id) else { return }
            do {
                try await center.add(request)
            } catch {
                notifierLog.error("No banner: \(String(describing: error), privacy: .public)")
            }
            if !posted.contains(id) { remove([banner.pane]) }
        }
    }

    /// The banners that went up, or wait to go up, and have not been removed.
    private var posted: Set<String> = []
    /// The one check of the permission that is in progress. Banners that come together share it,
    /// so the permission question shows once.
    private var authorization: Task<Bool, Never>?

    /// True when Loam may show a banner. The first call asks for the permission.
    private func authorized(_ center: UNUserNotificationCenter) async -> Bool {
        if let authorization { return await authorization.value }
        let check = Task { () -> Bool in
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional: return true
            case .notDetermined: return (try? await center.requestAuthorization(options: [.alert])) == true
            default: return false
            }
        }
        authorization = check
        let result = await check.value
        // You can change the setting in System Settings, so the next banner checks again.
        authorization = nil
        return result
    }

    func remove(_ panes: [PaneID]) {
        let ids = panes.map(\.uuidString)
        posted.subtract(ids)
        center?.removeDeliveredNotifications(withIdentifiers: ids)
        center?.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let pane = UUID(uuidString: response.notification.request.identifier) else { return }
        await MainActor.run { onOpen?(pane) }
    }

    /// Loam is frontmost: the pane ring and the sidebar show the state, so no banner shows.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}

private let notifierLog = Logger(subsystem: "dev.loam.Loam", category: "attention")
