import Foundation

/// Calm wording for a notification's age. Seconds are deliberately absent: a
/// live countdown draws the eye to a panel that is meant to stay quiet.
public enum RelativeTime {
    public static func describe(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }           // includes clock skew into the future
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 24 * 3600 {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        return date.formatted(style.day().month(.abbreviated))
    }
}
