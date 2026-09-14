import XCTest
@testable import Cleanora

final class SchedulerSettingsViewModelTests: XCTestCase {
    // MARK: - Interval clamping

    func testIntervalChoicesCoverTheAcceptedRange() {
        XCTAssertEqual(SchedulerSettingsViewModel.intervalChoices, Array(1...30))
    }

    func testPickerValuesInsideRangeAreStoredVerbatim() {
        XCTAssertEqual(SchedulerSettingsViewModel.sanitizedInterval(pickerValue: 7, current: 3), 7)
        XCTAssertEqual(SchedulerSettingsViewModel.sanitizedInterval(pickerValue: 1, current: 7), 1)
        XCTAssertEqual(SchedulerSettingsViewModel.sanitizedInterval(pickerValue: 30, current: 7), 30)
    }

    func testOutOfReachPickerValuesKeepTheCurrentPreference() {
        // The picker can only offer 1...30; anything else must not move the
        // stored value (defense against a stale binding).
        XCTAssertEqual(SchedulerSettingsViewModel.sanitizedInterval(pickerValue: 0, current: 7), 7)
        XCTAssertEqual(SchedulerSettingsViewModel.sanitizedInterval(pickerValue: 31, current: 7), 7)
        XCTAssertEqual(SchedulerSettingsViewModel.sanitizedInterval(pickerValue: -3, current: 12), 12)
    }

    func testReadingClampsEvenWhenTheStoredValueIsOutOfRange() {
        var preferences = Preferences()
        preferences.scheduleIntervalDays = 400
        XCTAssertEqual(preferences.clampedScheduleIntervalDays, 30)
        preferences.scheduleIntervalDays = 0
        XCTAssertEqual(preferences.clampedScheduleIntervalDays, 1)
        XCTAssertEqual(
            preferences.scheduleInterval,
            TimeInterval(1) * Preferences.secondsPerDay
        )
    }

    // MARK: - Labels

    func testIntervalLabelSingularAndPlural() {
        XCTAssertEqual(SchedulerSettingsViewModel.intervalLabel(for: 1), "1 day")
        XCTAssertEqual(SchedulerSettingsViewModel.intervalLabel(for: 7), "7 days")
    }

    func testRunNowTitleReflectsRunningState() {
        XCTAssertEqual(SchedulerSettingsViewModel.runNowTitle(isRunning: false), "Run now")
        XCTAssertEqual(SchedulerSettingsViewModel.runNowTitle(isRunning: true), "Scanning…")
    }

    func testCopyExplainsTheSafeOnlyContract() {
        XCTAssertTrue(SchedulerSettingsViewModel.safeOnlyHint.contains("never emptied"))
        XCTAssertTrue(
            SchedulerSettingsViewModel.safeOnlyHint.contains("Review items"),
            "the safe-only note must name what is never touched"
        )
        XCTAssertFalse(SchedulerSettingsViewModel.runNowHint.isEmpty)
    }

    // MARK: - Run lines

    func testLastRunLineIsNilBeforeTheFirstRun() {
        XCTAssertNil(SchedulerSettingsViewModel.lastRunLine(for: nil))
    }

    func testLastRunLineFormatsTheTimestamp() {
        let line = SchedulerSettingsViewModel.lastRunLine(
            for: VMFixtures.fixedNow,
            locale: VMFixtures.posixLocale,
            timeZone: VMFixtures.gregorianGMT.timeZone
        )
        XCTAssertEqual(line, "Last scheduled run: September 12, 2026, 10:42 AM")
    }

    func testNextRunLineNeedsEnabledScheduleAndAPreviousRun() {
        XCTAssertNil(SchedulerSettingsViewModel.nextRunLine(
            scheduleEnabled: false,
            lastRun: VMFixtures.fixedNow,
            intervalDays: 7,
            now: VMFixtures.fixedNow
        ))
        XCTAssertNil(SchedulerSettingsViewModel.nextRunLine(
            scheduleEnabled: true,
            lastRun: nil,
            intervalDays: 7,
            now: VMFixtures.fixedNow
        ))
    }

    func testNextRunLineProjectsLastRunPlusInterval() {
        let next = SchedulerSettingsViewModel.nextRunLine(
            scheduleEnabled: true,
            lastRun: VMFixtures.fixedNow,
            intervalDays: 7,
            now: VMFixtures.fixedNow,
            calendar: VMFixtures.gregorianGMT,
            locale: VMFixtures.posixLocale,
            timeZone: VMFixtures.gregorianGMT.timeZone
        )
        let expected = VMFixtures.fixedNow.addingTimeInterval(7 * Preferences.secondsPerDay)
        XCTAssertEqual(
            next,
            "Next scheduled scan: " + DateFormatting.longDateTime(
                expected,
                locale: VMFixtures.posixLocale,
                timeZone: VMFixtures.gregorianGMT.timeZone
            )
        )
    }

    func testOverdueSlotNeverPromisesAPastTime() {
        let longAgo = VMFixtures.fixedNow.addingTimeInterval(-90 * Preferences.secondsPerDay)
        let line = SchedulerSettingsViewModel.nextRunLine(
            scheduleEnabled: true,
            lastRun: longAgo,
            intervalDays: 7,
            now: VMFixtures.fixedNow,
            calendar: VMFixtures.gregorianGMT,
            locale: VMFixtures.posixLocale,
            timeZone: VMFixtures.gregorianGMT.timeZone
        )
        // An overdue slot fires "now", so the line can never show a past time.
        XCTAssertEqual(
            line,
            "Next scheduled scan: " + DateFormatting.longDateTime(
                VMFixtures.fixedNow,
                locale: VMFixtures.posixLocale,
                timeZone: VMFixtures.gregorianGMT.timeZone
            )
        )
    }
}
