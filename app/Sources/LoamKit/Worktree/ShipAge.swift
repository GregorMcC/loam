import Foundation

/// How old the ship state in the Worktrees section is (ticket 108). The core keeps the last answer of
/// GitHub when a refresh fails (offline, a rate limit), so the rows can be old. The header of the
/// section says when the answer came, once it is more than 5 minutes old.
public enum ShipAge {
    /// A ship state that is older than this shows its age.
    public static let staleAfter: TimeInterval = 5 * 60

    /// "Updated 18:02" for the oldest ship state among the rows, when that is more than `staleAfter`
    /// old. Nil when the data is fresh, and when no row has a time (GitHub never answered, or the
    /// folder is gone). A time on another day shows the day too.
    public static func label(for rows: [WorktreeStatus], now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        let dated = rows.filter { !$0.missing }.compactMap { row -> (at: String, date: Date)? in
            guard let at = row.prCheckedAt, let date = ChangeRules.date(at) else { return nil }
            return (at, date)
        }
        guard let oldest = dated.min(by: { $0.date < $1.date }),
              now.timeIntervalSince(oldest.date) > staleAfter else { return nil }
        return "Updated \(ChangeRules.stamp(oldest.at, now: now, timeZone: timeZone))"
    }
}
