import Foundation
import Observation

/// Settings > Runs: the limits of every run, and the usage that the hold reads. The core keeps both.
@MainActor
@Observable
public final class RunsSettingsModel {
    /// A reading that is older than this is read again when the tab opens. A read costs a small Claude call.
    public static let staleAfter: TimeInterval = 30 * 60

    @ObservationIgnored private let client: LoamClient
    @ObservationIgnored private let now: () -> Date
    /// The limits as the core last gave them. Nil before the first read.
    public private(set) var limits: RunLimits?
    public private(set) var usage: Usage?
    /// The paths and hosts that you add to the sandbox of every run.
    public let sandbox: SandboxSettingsModel
    /// Why the last change failed, or nil.
    public private(set) var error: String?
    @ObservationIgnored private var refreshing = false

    public init(client: LoamClient, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.now = now
        self.sandbox = SandboxSettingsModel(client: client)
    }

    /// Reads the limits and the last usage. The usage is read again only when it is older than 30 minutes.
    public func load() async {
        do {
            limits = try await client.runLimits()
            usage = try await client.usage()
            if Self.isStale(usage, now: now()), !refreshing {
                refreshing = true
                defer { refreshing = false }
                usage = try await client.usage(refresh: true)
            }
            error = nil
        } catch {
            self.error = AppModel.message(for: error)
        }
    }

    /// Saves one limit. A value out of range is brought into range first.
    public func setAtATime(_ value: Int) async { await save { $0.atATime = Self.clamp(value, 1, 20) } }
    public func setMaxTurns(_ value: Int) async { await save { $0.maxTurns = Self.clamp(value, 0, 1000) } }
    public func setHoldAt(_ value: Int) async { await save { $0.holdAt = Self.clamp(value, 0, 100) } }

    private func save(_ change: (inout RunLimits) -> Void) async {
        guard var next = limits else { return }
        change(&next)
        guard next != limits else { return }
        do {
            limits = try await client.setRunLimits(next)
            error = nil
        } catch {
            self.error = AppModel.message(for: error)
        }
    }

    static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int { min(max(value, low), high) }

    /// True when there is no reading, or it is older than 30 minutes.
    static func isStale(_ usage: Usage?, now: Date) -> Bool {
        guard let read = usage?.readAt.flatMap(parse) else { return true }
        return now.timeIntervalSince(read) > staleAfter
    }

    /// "41% used, resets Mon 09:00", or nil before the first report.
    public var usageWords: String? { Self.usageWords(usage, now: now()) }

    static func usageWords(_ usage: Usage?, now: Date, calendar: Calendar = .current) -> String? {
        guard let week = usage?.sevenDay else { return nil }
        let percent = Int((week.utilization * 100).rounded())
        guard let reset = parse(week.resetsAt) else { return "\(percent)% used" }
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "en_GB")
        format.dateFormat = reset.timeIntervalSince(now) < 6 * 24 * 3600 ? "EEE HH:mm" : "d MMM HH:mm"
        return "\(percent)% used, resets \(format.string(from: reset))"
    }

    private static func parse(_ iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ISO8601DateFormatter().date(from: iso) ?? fractional.date(from: iso)
    }
}
