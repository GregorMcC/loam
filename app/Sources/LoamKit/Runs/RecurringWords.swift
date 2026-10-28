import Foundation

/// The words of a recurring run for a person (ticket 208): its timetable, and its times as days of the week.
public enum RecurringWords {
    static let week = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// The day sets that the form offers, in its order.
    public static let daySets: [(name: String, days: [String])] = [
        ("Weekdays", ["mon", "tue", "wed", "thu", "fri"]),
        ("Every day", week),
        ("Weekends", ["sun", "sat"]),
        ("Mondays", ["mon"]),
    ]

    /// "Recurring runs · Loam redesign", or "Recurring runs" when the plot has no name.
    public static func pageTitle(plot: String) -> String {
        plot.isEmpty ? "Recurring runs" : "Recurring runs \u{00B7} \(plot)"
    }

    /// "Weekdays 06:30", "Every day 02:00", or "Mon, Wed 07:00".
    public static func timetable(days: [String], at: String) -> String {
        let sorted = week.filter(days.contains)
        if let set = daySets.first(where: { $0.days == sorted && $0.name != "Mondays" }) { return "\(set.name) \(at)" }
        let names = sorted.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return "\(names.joined(separator: ", ")) \(at)"
    }

    /// "today 06:30", "tomorrow 06:30", "yesterday 02:00", "Friday 06:30" within a week, else "28 Oct 06:30".
    public static func when(_ iso: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = parse(iso) else { return iso }
        let clock = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "today \(clock)"
        case 1: return "tomorrow \(clock)"
        case -1: return "yesterday \(clock)"
        case -6...6: return "\(date.formatted(.dateTime.weekday(.wide))) \(clock)"
        default: return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(clock)"
        }
    }

    /// Reads an RFC 3339 time, with or without fractional seconds.
    static func parse(_ iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ISO8601DateFormatter().date(from: iso) ?? fractional.date(from: iso)
    }
}
