import XCTest
@testable import Cleanora

@MainActor
final class HistoryViewModelTests: XCTestCase {
    private let calendar = VMFixtures.gregorianGMT
    private let locale = VMFixtures.posixLocale
    private let timeZone = TimeZone(identifier: "GMT")!

    /// Date = fixedNow − daysAgo days − hoursAgo hours.
    private func entry(daysAgo: Int, hoursAgo: Int = 0, bytes: Int64 = 1_000_000_000) -> CleanupHistoryEntry {
        let date = calendar.date(
            byAdding: DateComponents(day: -daysAgo, hour: -hoursAgo),
            to: VMFixtures.fixedNow
        )!
        return VMFixtures.historyEntry(date: date, bytesFreed: bytes)
    }

    func testDayGroupsTodayYesterdayAndPast() {
        let todayMorning = entry(daysAgo: 0, hoursAgo: 8)
        let todayLater = entry(daysAgo: 0, hoursAgo: 1)
        let yesterday = entry(daysAgo: 1)
        let threeDaysAgo = entry(daysAgo: 3)

        let groups = HistoryViewModel.dayGroups(
            for: [todayMorning, threeDaysAgo, yesterday, todayLater],
            now: VMFixtures.fixedNow,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(groups.count, 3, "one bucket per day, newest first")
        XCTAssertEqual(groups[0].label, "Today")
        XCTAssertEqual(groups[0].entries.count, 2)
        XCTAssertEqual(groups[1].label, "Yesterday")
        XCTAssertEqual(groups[2].label, "Sep 09", "zero-padded short day per spec §10")
    }

    func testEntriesSortNewestFirstWithinDay() {
        let morning = entry(daysAgo: 0, hoursAgo: 8)
        let later = entry(daysAgo: 0, hoursAgo: 1)
        let groups = HistoryViewModel.dayGroups(
            for: [morning, later],
            now: VMFixtures.fixedNow,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        XCTAssertEqual(groups[0].entries.first?.date, later.date, "newest entry first")
    }

    func testRefreshLoadsEntriesIntoGroups() {
        let kept = VMFixtures.historyEntry(date: VMFixtures.fixedNow)
        let store = [kept]
        let viewModel = HistoryViewModel(load: { store })

        viewModel.refresh(
            now: VMFixtures.fixedNow,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        XCTAssertEqual(viewModel.groups.count, 1)
        XCTAssertEqual(viewModel.entries, store)
    }

    func testEmptyHistoryHasNoGroups() {
        let viewModel = HistoryViewModel(load: { [] })
        viewModel.refresh(
            now: VMFixtures.fixedNow,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        XCTAssertTrue(viewModel.groups.isEmpty)
    }
}
