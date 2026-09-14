import Foundation

/// Decision logic + copy for the Settings Scheduler section (M-07). The
/// schedule itself lives in the engine's CleanupScheduler; this type keeps
/// the preferences-side math (interval clamping, next/last run lines) pure
/// and testable.
enum SchedulerSettingsViewModel {
    /// Picker choices, in days — exactly the accepted range, so the picker
    /// can never produce an out-of-range value.
    nonisolated static var intervalChoices: [Int] {
        Array(Preferences.scheduleIntervalDaysRange)
    }

    /// Picker label: "7 days" / "1 day".
    nonisolated static func intervalLabel(for days: Int) -> String {
        days == 1 ? "1 day" : "\(days) days"
    }

    /// Persisting an out-of-range value is refused rather than clamped, so
    /// the stored preference always matches what the user saw in the picker.
    /// (Reading still clamps — Preferences.clampedScheduleIntervalDays.)
    nonisolated static func sanitizedInterval(pickerValue: Int, current: Int) -> Int {
        Preferences.scheduleIntervalDaysRange.contains(pickerValue) ? pickerValue : current
    }

    static let safeOnlyHint =
        "Runs a scan every few days. When “Clean safe items automatically” is on, the " +
            "preselected safe items are cleaned too — never Review items, and the Trash " +
            "is never emptied. If anything can't be cleaned safely, the scan only records " +
            "what it found."

    static let runNowHint =
        "Runs the same scan a scheduled run would run, right now."

    /// "Last scheduled run: Sep 12, 2026, 9:00 AM"; nil before any run.
    nonisolated static func lastRunLine(
        for date: Date?,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let date else { return nil }
        return "Last scheduled run: " +
            DateFormatting.longDateTime(date, locale: locale, timeZone: timeZone)
    }

    /// "Next scheduled scan: Sep 19, 2026, 9:00 AM"; nil while disabled or
    /// before the first run (the first slot is scheduled at enable time).
    nonisolated static func nextRunLine(
        scheduleEnabled: Bool,
        lastRun: Date?,
        intervalDays: Int,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard scheduleEnabled, let lastRun else { return nil }
        let interval = TimeInterval(
            min(
                max(intervalDays, Preferences.scheduleIntervalDaysRange.lowerBound),
                Preferences.scheduleIntervalDaysRange.upperBound
            )
        ) * Preferences.secondsPerDay
        let next = lastRun.addingTimeInterval(interval)
        // An overdue slot fires on the next opportunity; promising a past
        // time would be a lie.
        let effective = next > now ? next : now
        return "Next scheduled scan: " +
            DateFormatting.longDateTime(effective, locale: locale, timeZone: timeZone)
    }

    nonisolated static func runNowTitle(isRunning: Bool) -> String {
        isRunning ? "Scanning…" : "Run now"
    }
}
