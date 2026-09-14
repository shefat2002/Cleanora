import XCTest
@testable import Cleanora

/// CleanupScheduler (M-02): interval firing, one catch-up on start, safe-only
/// clean selection, lastScheduledRun persistence, and cancellation — entirely
/// through injected seams. No real scans, no real deletions, and no real
/// waiting: the sleeper is gate-released by the test, and `now` is fixed.
@MainActor
final class CleanupSchedulerTests: TempHomeTestCase {
    /// Deterministic "now" for every scheduler in this suite.
    private let baseDate = Date(timeIntervalSince1970: 1_790_000_000)
    /// nonisolated(unsafe): written once in setUpWithError (nonisolated),
    /// read only from @MainActor test methods afterwards.
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var historyDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = UserDefaults(suiteName: "CleanupSchedulerTests-\(UUID().uuidString)")!
        historyDirectory = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
    }

    // MARK: - Test doubles

    /// Lock-based recorder: the injected closures are @Sendable, so shared
    /// state must be safe to touch from any task.
    private final class SeamRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _scanCount = 0
        private var _scannedOptions: [ScanOptions] = []
        private var _cleanSelections: [[UUID]] = []

        var scanCount: Int { lock.withLock { _scanCount } }
        var scannedOptions: [ScanOptions] { lock.withLock { _scannedOptions } }
        var cleanSelections: [[UUID]] { lock.withLock { _cleanSelections } }

        func recordScan(options: ScanOptions) {
            lock.withLock {
                _scanCount += 1
                _scannedOptions.append(options)
            }
        }

        func recordClean(ids: [UUID]) {
            lock.withLock { _cleanSelections.append(ids) }
        }
    }

    /// A `ScanResult?` box the injected scan closure returns; tests point it
    /// at different fixtures mid-suite.
    private final class ResultBox: @unchecked Sendable {
        var value: ScanResult?
        init(_ value: ScanResult?) { self.value = value }
    }

    /// Cancellation-aware, gate-released sleeper: the scheduler loop parks
    /// here until the test releases it, so no test ever waits a real interval.
    /// A `release()` that lands BEFORE the loop has parked (tests that call
    /// `start()` and `release()` back-to-back — same actor, so the loop cannot
    /// have suspended yet) is remembered and consumed by the next `sleep`;
    /// without that, the wakeup is lost and the fire never happens.
    private final class GatedSleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var requested: [TimeInterval] = []
        private var pending: CheckedContinuation<Void, any Error>?
        private var outstandingReleases = 0

        var requestedDelays: [TimeInterval] { lock.withLock { requested } }

        func sleep(_ delay: TimeInterval) async throws {
            let earlyRelease: Bool = lock.withLock {
                requested.append(delay)
                guard pending == nil, outstandingReleases > 0 else { return false }
                outstandingReleases -= 1
                return true
            }
            if earlyRelease { return }

            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    var resumeNow: (any Error)?
                    self.lock.withLock {
                        if Task.isCancelled {
                            resumeNow = CancellationError()
                        } else {
                            self.pending = continuation
                        }
                    }
                    if let resumeNow { continuation.resume(throwing: resumeNow) }
                }
            } onCancel: {
                self.wake(with: CancellationError())
            }
        }

        /// Lets one pending sleep return so the scheduler fires.
        func release() {
            let continuation: (CheckedContinuation<Void, any Error>)? = lock.withLock {
                if let current = pending {
                    pending = nil
                    return current
                }
                outstandingReleases += 1
                return nil
            }
            continuation?.resume(returning: ())
        }

        private func wake(with error: (any Error)?) {
            let continuation: (CheckedContinuation<Void, any Error>)? = lock.withLock {
                let current = pending
                pending = nil
                return current
            }
            if let error {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume(returning: ())
            }
        }
    }

    // MARK: - Fixtures

    private func makeItem(
        name: String,
        category: ScanCategory,
        risk: RiskLevel,
        confirmation: CleanupItem.ConfirmationLevel = .standard,
        selected: Bool? = nil
    ) -> CleanupItem {
        CleanupItem(
            name: name,
            category: category,
            path: tempHome
                .appendingPathComponent("Library/Caches/cleanora-scheduler/\(name)"),
            size: 1_000,
            riskLevel: risk,
            selected: selected,
            reason: "test fixture",
            deletionMethod: .trashDirectory,
            confirmationLevel: confirmation
        )
    }

    private func makeScanResult(items: [CleanupItem]) -> ScanResult {
        ScanResult(
            startedAt: baseDate.addingTimeInterval(-5),
            finishedAt: baseDate,
            items: items
        )
    }

    // MARK: - Assembly

    private func makeScheduler(
        recorder: SeamRecorder,
        resultBox: ResultBox,
        sleeper: GatedSleeper,
        enabled: Bool = true,
        autoClean: Bool = true,
        intervalDays: Int = 7,
        lastScheduledRun: Date? = nil
    ) -> CleanupScheduler {
        let store = PreferencesStore(defaults: defaults)
        store.update {
            $0.scheduleEnabled = enabled
            $0.scheduleIntervalDays = intervalDays
            $0.scheduleAutoCleanSafeOnly = autoClean
            $0.lastScheduledRun = lastScheduledRun
        }
        return CleanupScheduler(
            environment: environment,
            preferences: store,
            history: ScanHistoryStore(directory: historyDirectory),
            diskInfo: DiskInfoProvider(),
            scan: { options in
                recorder.recordScan(options: options)
                return resultBox.value
            },
            clean: { result in
                recorder.recordClean(ids: result.selectedItems.map(\.id))
            },
            sleeper: { delay in try await sleeper.sleep(delay) },
            now: { [baseDate] in baseDate }
        )
    }

    // MARK: - Disabled schedule

    func testStartWithScheduleDisabledIsANoOp() {
        let sleeper = GatedSleeper()
        let recorder = SeamRecorder()
        let scheduler = makeScheduler(
            recorder: recorder, resultBox: ResultBox(nil), sleeper: sleeper, enabled: false
        )

        scheduler.start()

        XCTAssertFalse(scheduler.isRunning)
        XCTAssertNil(scheduler.nextRun)
        XCTAssertTrue(sleeper.requestedDelays.isEmpty, "no loop was started")
        XCTAssertEqual(recorder.scanCount, 0)

        scheduler.stop() // must be harmless
        XCTAssertFalse(scheduler.isRunning)
    }

    // MARK: - Interval firing

    func testFiresAfterIntervalThenReschedulesNextInterval() async throws {
        let sleeper = GatedSleeper()
        let recorder = SeamRecorder()
        let cache = makeItem(name: "AppCache", category: .applicationCaches, risk: .safe)
        let resultBox = ResultBox(makeScanResult(items: [cache]))
        let scheduler = makeScheduler(
            recorder: recorder, resultBox: resultBox, sleeper: sleeper
        )

        scheduler.start()
        XCTAssertEqual(scheduler.nextRun, baseDate.addingTimeInterval(7 * 86_400),
                       "no previous run: first fire is one interval out")
        let conditionMet1 = await waitUntil { sleeper.requestedDelays.count == 1 }; XCTAssertTrue(conditionMet1)
        XCTAssertEqual(sleeper.requestedDelays.first ?? 0, 7 * 86_400, accuracy: 0.001)
        XCTAssertEqual(recorder.scanCount, 0, "nothing fires before the interval elapses")

        sleeper.release()
        let conditionMet2 = await waitUntil { recorder.scanCount == 1 }; XCTAssertTrue(conditionMet2)
        let conditionMet3 = await waitUntil { !recorder.cleanSelections.isEmpty }; XCTAssertTrue(conditionMet3)
        XCTAssertEqual(recorder.cleanSelections.first, [cache.id])

        // The fire consumed a schedule slot, persisted it, and recorded the
        // scan as finished; the loop then reschedules a fresh interval.
        XCTAssertEqual(recorder.scannedOptions.first?.enabledCategories,
                       Preferences().enabledCategories,
                       "the scan runs with the stored options")
        let conditionMet4 = await waitUntil { sleeper.requestedDelays.count == 2 }; XCTAssertTrue(conditionMet4)
        XCTAssertEqual(sleeper.requestedDelays.last ?? 0, 7 * 86_400, accuracy: 0.001)

        let persisted = ScanHistoryStore(directory: historyDirectory).lastScan()
        XCTAssertEqual(persisted?.id, resultBox.value?.id)
        XCTAssertEqual(PreferencesStore(defaults: defaults).value.lastScheduledRun, baseDate)

        scheduler.stop()
    }

    func testDoubleStartDoesNotSpawnSecondLoop() async throws {
        let sleeper = GatedSleeper()
        let recorder = SeamRecorder()
        let resultBox = ResultBox(makeScanResult(items: []))
        let scheduler = makeScheduler(
            recorder: recorder, resultBox: resultBox, sleeper: sleeper
        )

        scheduler.start()
        scheduler.start()

        let conditionMet5 = await waitUntil { sleeper.requestedDelays.count == 1 }; XCTAssertTrue(conditionMet5)
        sleeper.release()
        let conditionMet6 = await waitUntil { recorder.scanCount == 1 }; XCTAssertTrue(conditionMet6)
        // Give a hypothetical second loop time to misfire; it must not exist.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.scanCount, 1)
        XCTAssertEqual(sleeper.requestedDelays.count, 2, "one loop: exactly one follow-up sleep")

        scheduler.stop()
    }

    // MARK: - Catch-up on start

    func testOverdueScheduleRunsExactlyOneCatchUpFireOnStart() async throws {
        let sleeper = GatedSleeper()
        let recorder = SeamRecorder()
        let cache = makeItem(name: "AppCache", category: .applicationCaches, risk: .safe)
        let resultBox = ResultBox(makeScanResult(items: [cache]))
        let scheduler = makeScheduler(
            recorder: recorder, resultBox: resultBox, sleeper: sleeper,
            intervalDays: 1,
            lastScheduledRun: baseDate.addingTimeInterval(-3 * 86_400) // 3 missed periods
        )

        scheduler.start()

        // The catch-up fires WITHOUT any released sleep — immediately on start.
        let conditionMet7 = await waitUntil { recorder.scanCount == 1 }; XCTAssertTrue(conditionMet7)
        let conditionMet8 = await waitUntil { sleeper.requestedDelays.count == 1 }; XCTAssertTrue(conditionMet8)
        XCTAssertEqual(sleeper.requestedDelays.first ?? 0, 86_400, accuracy: 0.001,
                       "after the catch-up, the cadence resyncs to a full interval")
        XCTAssertEqual(PreferencesStore(defaults: defaults).value.lastScheduledRun, baseDate)

        // At most ONE catch-up: releasing the gate produces the NEXT regular
        // fire, not a burst replaying the two other missed periods.
        sleeper.release()
        let conditionMet9 = await waitUntil { recorder.scanCount == 2 }; XCTAssertTrue(conditionMet9)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.scanCount, 2)

        scheduler.stop()
    }

    func testNotYetDueScheduleResumesOriginalCadenceWithoutCatchUp() async throws {
        let sleeper = GatedSleeper()
        let recorder = SeamRecorder()
        let resultBox = ResultBox(makeScanResult(items: []))
        let scheduler = makeScheduler(
            recorder: recorder, resultBox: resultBox, sleeper: sleeper,
            intervalDays: 1,
            lastScheduledRun: baseDate.addingTimeInterval(-3_600) // fired an hour ago
        )

        scheduler.start()

        let conditionMet10 = await waitUntil { sleeper.requestedDelays.count == 1 }; XCTAssertTrue(conditionMet10)
        XCTAssertEqual(recorder.scanCount, 0, "no catch-up before the slot is due")
        XCTAssertEqual(sleeper.requestedDelays.first ?? 0, 86_400 - 3_600, accuracy: 1.0,
                       "the remaining time of the original interval, not a fresh one")
        XCTAssertEqual(scheduler.nextRun, baseDate.addingTimeInterval(-3_600 + 86_400))

        sleeper.release()
        let conditionMet11 = await waitUntil { recorder.scanCount == 1 }; XCTAssertTrue(conditionMet11)

        scheduler.stop()
    }

    // MARK: - Safe-only clean selection

    func testCleanClosureReceivesOnlyPreselectedSafeNonDestructiveIDs() async throws {
        let sleeper = GatedSleeper()
        let recorder = SeamRecorder()
        let safeCache = makeItem(name: "AppCache", category: .applicationCaches, risk: .safe)
        let safeTemp = makeItem(name: "TempFile", category: .temporaryFiles, risk: .safe)
        let reviewFile = makeItem(name: "BigFile", category: .largeFiles, risk: .review)
        let trash = makeItem(
            name: "Trash", category: .trash, risk: .safe,
            confirmation: .destructive
        )
        let deselected = makeItem(
            name: "Deselected", category: .browserCaches, risk: .safe, selected: false
        )
        let resultBox = ResultBox(makeScanResult(items: [safeCache, reviewFile, trash, safeTemp, deselected]))
        let scheduler = makeScheduler(
            recorder: recorder, resultBox: resultBox, sleeper: sleeper
        )

        scheduler.start()
        sleeper.release()
        let conditionMet12 = await waitUntil { !recorder.cleanSelections.isEmpty }; XCTAssertTrue(conditionMet12)

        XCTAssertEqual(
            Set(recorder.cleanSelections.first ?? []),
            [safeCache.id, safeTemp.id],
            "review, destructive (Trash), and deselected items never reach the clean"
        )

        scheduler.stop()
    }

    func testNotifyOnlyModeScansAndRecordsButNeverCleans() async throws {
        let sleeper = GatedSleeper()
        let recorder = SeamRecorder()
        let cache = makeItem(name: "AppCache", category: .applicationCaches, risk: .safe)
        let resultBox = ResultBox(makeScanResult(items: [cache]))
        let scheduler = makeScheduler(
            recorder: recorder, resultBox: resultBox, sleeper: sleeper, autoClean: false
        )

        scheduler.start()
        sleeper.release()
        let conditionMet13 = await waitUntil { recorder.scanCount == 1 }; XCTAssertTrue(conditionMet13)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(recorder.cleanSelections, [], "notify-only: nothing is cleaned")
        XCTAssertEqual(
            ScanHistoryStore(directory: historyDirectory).lastScan()?.id,
            resultBox.value?.id,
            "the scheduled scan is still recorded as finished"
        )

        scheduler.stop()
    }

    func testNothingSafeToCleanSkipsTheClean() async throws {
        let sleeper = GatedSleeper()
        let recorder = SeamRecorder()
        let reviewFile = makeItem(name: "BigFile", category: .largeFiles, risk: .review)
        let resultBox = ResultBox(makeScanResult(items: [reviewFile]))
        let scheduler = makeScheduler(
            recorder: recorder, resultBox: resultBox, sleeper: sleeper
        )

        scheduler.start()
        sleeper.release()
        let conditionMet14 = await waitUntil { recorder.scanCount == 1 }; XCTAssertTrue(conditionMet14)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(recorder.cleanSelections, [], "an empty safe selection cleans nothing")

        scheduler.stop()
    }

    func testScanFailureSkipsCleanButLoopStaysAlive() async throws {
        let sleeper = GatedSleeper()
        let recorder = SeamRecorder()
        let resultBox = ResultBox(nil)
        let scheduler = makeScheduler(
            recorder: recorder, resultBox: resultBox, sleeper: sleeper
        )

        scheduler.start()
        sleeper.release()
        let conditionMet15 = await waitUntil { recorder.scanCount == 1 }; XCTAssertTrue(conditionMet15)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.cleanSelections, [])

        // The loop survives a nil scan: the next slot still fires.
        sleeper.release()
        let conditionMet16 = await waitUntil { recorder.scanCount == 2 }; XCTAssertTrue(conditionMet16)

        scheduler.stop()
    }

    // MARK: - Persistence + resume

    func testLastScheduledRunPersistsAndResumesWithoutCatchUp() async throws {
        let sleeper = GatedSleeper()
        let recorder = SeamRecorder()
        let resultBox = ResultBox(makeScanResult(items: []))
        let first = makeScheduler(
            recorder: recorder, resultBox: resultBox, sleeper: sleeper
        )

        first.start()
        sleeper.release()
        let conditionMet17 = await waitUntil { recorder.scanCount == 1 }; XCTAssertTrue(conditionMet17)
        first.stop()

        // A new scheduler over the same persisted preferences resumes: the
        // slot fired "just now" (fixed clock), so there is no catch-up.
        let secondSleeper = GatedSleeper()
        let secondRecorder = SeamRecorder()
        let second = makeScheduler(
            recorder: secondRecorder, resultBox: resultBox, sleeper: secondSleeper,
            lastScheduledRun: PreferencesStore(defaults: defaults).value.lastScheduledRun
        )

        second.start()
        let conditionMet18 = await waitUntil { secondSleeper.requestedDelays.count == 1 }; XCTAssertTrue(conditionMet18)
        XCTAssertEqual(secondRecorder.scanCount, 0, "not overdue: no immediate fire")
        XCTAssertEqual(secondSleeper.requestedDelays.first ?? 0, 7 * 86_400, accuracy: 0.001)

        second.stop()
    }

    // MARK: - Cancellation

    func testStopCancelsTheLoopAndPreventsFurtherFires() async throws {
        let sleeper = GatedSleeper()
        let recorder = SeamRecorder()
        let resultBox = ResultBox(makeScanResult(items: []))
        let scheduler = makeScheduler(
            recorder: recorder, resultBox: resultBox, sleeper: sleeper
        )

        scheduler.start()
        let conditionMet19 = await waitUntil { sleeper.requestedDelays.count == 1 }; XCTAssertTrue(conditionMet19)
        XCTAssertTrue(scheduler.isRunning)

        scheduler.stop()
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertNil(scheduler.nextRun)

        // The parked sleep is cancelled with the task; a late release finds
        // nothing to wake and no further fires can happen.
        try await Task.sleep(for: .milliseconds(50))
        sleeper.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.scanCount, 0)
    }

    // MARK: - Interval clamping end-to-end

    func testIntervalDaysBelowRangeIsClampedToOneDay() async throws {
        try await assertEndToEndInterval(days: 0, expectDelay: 86_400)
    }

    func testIntervalDaysAboveRangeIsClampedToThirtyDays() async throws {
        try await assertEndToEndInterval(days: 99, expectDelay: 30 * 86_400)
    }

    private func assertEndToEndInterval(days: Int, expectDelay: TimeInterval) async throws {
        let sleeper = GatedSleeper()
        let recorder = SeamRecorder()
        let resultBox = ResultBox(makeScanResult(items: []))
        let scheduler = makeScheduler(
            recorder: recorder, resultBox: resultBox, sleeper: sleeper, intervalDays: days
        )

        scheduler.start()
        let conditionMet20 = await waitUntil { sleeper.requestedDelays.count == 1 }; XCTAssertTrue(conditionMet20)
        XCTAssertEqual(sleeper.requestedDelays.first ?? 0, expectDelay, accuracy: 0.001)

        scheduler.stop()
    }

    // MARK: - Selection helpers (used by App wiring too)

    func testScheduledCleanSelectionComputesSafeNonDestructiveSet() {
        let safe = makeItem(name: "Safe", category: .applicationCaches, risk: .safe)
        let review = makeItem(name: "Review", category: .largeFiles, risk: .review)
        let trash = makeItem(name: "Trash", category: .trash, risk: .safe, confirmation: .destructive)
        let destructiveFlagged = makeItem(
            name: "Flagged", category: .applicationCaches, risk: .safe, confirmation: .destructive
        )
        let result = makeScanResult(items: [safe, review, trash, destructiveFlagged])

        XCTAssertEqual(
            CleanupScheduler.scheduledCleanSelection(in: result),
            [safe.id]
        )
    }

    func testMarkingSelectionLeavesOnlyChosenItemsSelected() {
        let safe = makeItem(name: "Safe", category: .applicationCaches, risk: .safe)
        let review = makeItem(name: "Review", category: .largeFiles, risk: .review)
        let result = makeScanResult(items: [safe, review])

        let marked = CleanupScheduler.markingSelection(
            [safe.id], on: result
        )

        XCTAssertEqual(marked.id, result.id, "same scan identity")
        XCTAssertEqual(marked.selectedItems.map(\.id), [safe.id])
        XCTAssertEqual(marked.summaries, result.summaries)
    }
}
