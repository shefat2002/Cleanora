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

    // MARK: Clear history (P-11)

    func testClearHistoryDeletesAndRefreshesWhenCapabilityInjected() {
        final class Flag { var value = false }
        let flag = Flag()
        let kept = VMFixtures.historyEntry(date: VMFixtures.fixedNow)
        let viewModel = HistoryViewModel(
            load: { flag.value ? [] : [kept] },
            clear: { flag.value = true }
        )
        viewModel.refresh(now: VMFixtures.fixedNow, calendar: calendar, locale: locale, timeZone: timeZone)
        XCTAssertEqual(viewModel.groups.count, 1)
        XCTAssertTrue(viewModel.canClearHistory)

        viewModel.clearHistory()

        XCTAssertTrue(flag.value, "the store capability was invoked")
        XCTAssertTrue(viewModel.groups.isEmpty, "groups re-derive after the store call")
        XCTAssertTrue(viewModel.entries.isEmpty)
    }

    func testClearIsHiddenAndNoOpWhenStoreLacksTheCapability() {
        let kept = VMFixtures.historyEntry(date: VMFixtures.fixedNow)
        let viewModel = HistoryViewModel(load: { [kept] })
        viewModel.refresh(now: VMFixtures.fixedNow, calendar: calendar, locale: locale, timeZone: timeZone)

        XCTAssertFalse(viewModel.canClearHistory, "no store clear API yet — the UI hides the button")
        viewModel.clearHistory()
        XCTAssertEqual(viewModel.groups.count, 1, "clearing without a capability changes nothing")
    }

    /// Cross-check (P-11): the view model's day grouping must agree with the
    /// store's `historyGroupedByDay()` on both the day order and membership.
    func testDayGroupingAgreesWithStoreGroupedAPI() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanora-hist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = ScanHistoryStore(directory: folder)
        let today = VMFixtures.historyEntry(date: VMFixtures.fixedNow.addingTimeInterval(-600))
        let earlierToday = VMFixtures.historyEntry(date: VMFixtures.fixedNow.addingTimeInterval(-3_600))
        let threeDaysAgo = VMFixtures.historyEntry(
            date: VMFixtures.gregorianGMT.date(byAdding: .day, value: -3, to: VMFixtures.fixedNow)!
        )
        store.appendHistory(today)
        store.appendHistory(earlierToday)
        store.appendHistory(threeDaysAgo)

        let storeGroups = store.historyGroupedByDay()
        let viewModel = HistoryViewModel(load: { store.history() })
        viewModel.refresh(now: VMFixtures.fixedNow, calendar: calendar, locale: locale, timeZone: timeZone)

        XCTAssertEqual(viewModel.groups.count, storeGroups.count)
        XCTAssertEqual(viewModel.groups.map(\.label), ["Today", "Sep 09"])
        for (index, vmGroup) in viewModel.groups.enumerated() {
            let storeDay = try XCTUnwrap(storeGroups[index].entries.first?.date).startOfDayGMT
            XCTAssertEqual(
                calendar.startOfDay(for: try XCTUnwrap(vmGroup.entries.first?.date)),
                storeDay,
                "same entries per day, same order"
            )
            XCTAssertEqual(vmGroup.entries.count, storeGroups[index].entries.count)
        }
    }
}

private extension Date {
    var startOfDayGMT: Date {
        VMFixtures.gregorianGMT.startOfDay(for: self)
    }
}
