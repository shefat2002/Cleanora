import Foundation

/// Deterministic, injectable date formatting for the app surfaces: the
/// dashboard "Last scan" line, history day headers, and the completion
/// timestamp. Every function takes `now`/`calendar`/`locale`/`timeZone` so
/// tests pin them; the app passes the defaults from callers that want
/// current values.
enum DateFormatting {
    /// "Today" / "Yesterday" / "Sep 08" — history day group headers.
    static func dayLabel(
        for date: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return normalized(
            shortDayFormatter(locale: locale, timeZone: timeZone).string(from: date)
        )
    }

    /// "Today, 10:42 AM" / "Yesterday, 4:02 PM" / "Sep 08, 2:15 PM" — the
    /// dashboard's last-scan line.
    static func timestampLine(
        for date: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let day = dayLabel(for: date, now: now, calendar: calendar, locale: locale, timeZone: timeZone)
        let time = normalized(
            formatter(dateStyle: .none, timeStyle: .short, locale: locale, timeZone: timeZone)
                .string(from: date)
        )
        if day == "Today" || day == "Yesterday" {
            return "\(day), \(time)"
        }
        let dayAndTime = shortDayFormatter(locale: locale, timeZone: timeZone)
        dayAndTime.dateFormat = "MMM dd, h:mm a"
        return normalized(dayAndTime.string(from: date))
    }

    /// ICU emits narrow no-break spaces before AM/PM in some locales; they
    /// render inconsistently next to hand-set copy, so all output is
    /// normalized to plain spaces.
    private static func normalized(_ string: String) -> String {
        string
            .replacing("\u{202F}", with: " ")
            .replacing("\u{00A0}", with: " ")
    }

    /// "Sep 08" — past-day headers use the spec's zero-padded short form.
    private static func shortDayFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM dd"
        return formatter
    }

    /// "September 12, 2026 • 5:42 PM" — completion and history detail.
    static func longDateTime(
        _ date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return normalized(formatter.string(from: date))
    }

    private static func formatter(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        locale: Locale,
        timeZone: TimeZone
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }
}
