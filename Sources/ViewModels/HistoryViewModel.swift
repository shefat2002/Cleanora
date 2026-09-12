import Foundation
import Observation

/// Cleanup history: day-grouped entries ("Today", "Yesterday", "Sep 08") and
/// a selected-entry detail. Grouping is pure and clock-injectable.
@MainActor
@Observable
final class HistoryViewModel {
    struct DayGroup: Identifiable, Equatable {
        let label: String
        /// Newest first within the day.
        let entries: [CleanupHistoryEntry]
        var id: String { label }
        var bytesFreed: Int64 { entries.reduce(0) { $0 + $1.bytesFreed } }
    }

    private(set) var entries: [CleanupHistoryEntry] = []
    private(set) var groups: [DayGroup] = []

    private let load: () -> [CleanupHistoryEntry]
    /// Deleting history is a storage capability, injected; nil while the
    /// store has no clear API, in which case the UI hides the button.
    private let clear: (@MainActor () -> Void)?

    init(
        load: @escaping () -> [CleanupHistoryEntry],
        clear: (@MainActor () -> Void)? = nil
    ) {
        self.load = load
        self.clear = clear
    }

    convenience init(environment: AppEnvironment) {
        self.init(load: { environment.scanHistoryStore.history() })
    }

    var canClearHistory: Bool { clear != nil }

    /// Deletes every history entry through the injected store call and
    /// re-derives the day groups.
    func clearHistory() {
        guard let clear else { return }
        clear()
        refresh()
    }

    func refresh(
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        entries = load()
        groups = Self.dayGroups(
            for: entries,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
    }

    // MARK: - Pure logic

    static func dayGroups(
        for entries: [CleanupHistoryEntry],
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> [DayGroup] {
        let sorted = entries.sorted { $0.date > $1.date }
        var buckets: [(startOfDay: Date, entries: [CleanupHistoryEntry])] = []
        for entry in sorted {
            let dayStart = calendar.startOfDay(for: entry.date)
            if let index = buckets.firstIndex(where: {
                calendar.isDate($0.startOfDay, inSameDayAs: entry.date)
            }) {
                buckets[index].entries.append(entry)
            } else {
                buckets.append((dayStart, [entry]))
            }
        }
        return buckets.map { bucket in
            DayGroup(
                label: DateFormatting.dayLabel(
                    for: bucket.startOfDay,
                    now: now,
                    calendar: calendar,
                    locale: locale,
                    timeZone: timeZone
                ),
                entries: bucket.entries
            )
        }
    }
}
