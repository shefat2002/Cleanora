import XCTest
@testable import Cleanora

final class DateFormattingTests: XCTestCase {
    private let calendar = VMFixtures.gregorianGMT
    private let locale = VMFixtures.posixLocale
    private let timeZone = TimeZone(identifier: "GMT")!
    private let now = VMFixtures.fixedNow // 2026-09-12 10:42 GMT

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        VMFixtures.gregorianGMT.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    func testTimestampLineForTodayYesterdayAndPast() {
        XCTAssertEqual(
            DateFormatting.timestampLine(for: date(year: 2026, month: 9, day: 12, hour: 10, minute: 42), now: now, calendar: calendar, locale: locale, timeZone: timeZone),
            "Today, 10:42 AM"
        )
        XCTAssertEqual(
            DateFormatting.timestampLine(for: date(year: 2026, month: 9, day: 11, hour: 16, minute: 2), now: now, calendar: calendar, locale: locale, timeZone: timeZone),
            "Yesterday, 4:02 PM"
        )
        XCTAssertEqual(
            DateFormatting.timestampLine(for: date(year: 2026, month: 9, day: 8, hour: 14, minute: 15), now: now, calendar: calendar, locale: locale, timeZone: timeZone),
            "Sep 08, 2:15 PM"
        )
    }

    func testDayLabel() {
        XCTAssertEqual(
            DateFormatting.dayLabel(for: date(year: 2026, month: 9, day: 12, hour: 0, minute: 0), now: now, calendar: calendar, locale: locale, timeZone: timeZone),
            "Today"
        )
        XCTAssertEqual(
            DateFormatting.dayLabel(for: date(year: 2026, month: 9, day: 11, hour: 23, minute: 59), now: now, calendar: calendar, locale: locale, timeZone: timeZone),
            "Yesterday"
        )
        XCTAssertEqual(
            DateFormatting.dayLabel(for: date(year: 2026, month: 8, day: 25, hour: 9, minute: 0), now: now, calendar: calendar, locale: locale, timeZone: timeZone),
            "Aug 25"
        )
    }

    func testLongDateTime() {
        XCTAssertEqual(
            DateFormatting.longDateTime(date(year: 2026, month: 9, day: 12, hour: 17, minute: 42), locale: locale, timeZone: timeZone),
            "September 12, 2026 at 5:42 PM"
        )
    }
}
