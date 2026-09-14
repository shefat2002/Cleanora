import XCTest
@testable import Cleanora

/// O-01 + O-02 — ScanCoordinator: concurrency, cancellation, throttling,
/// failure isolation, dedup (I8) and summaries.
final class ScanCoordinatorTests: TempHomeTestCase {
    // MARK: - Helpers

    private func makeCoordinator(
        _ scanners: [any Cleanora.Scanner],
        options: ScanOptions = ScanOptions(),
        diskInfo: DiskInfoProvider = DiskInfoProvider()
    ) -> ScanCoordinator {
        ScanCoordinator(
            scanners: scanners,
            environment: environment,
            options: options,
            diskInfo: diskInfo
        )
    }

    @discardableResult
    private func consume(_ stream: AsyncStream<ScanUpdate>) async
        -> (updates: [ScanUpdate], duration: TimeInterval) {
        let clock = ContinuousClock()
        var updates: [ScanUpdate] = []
        let start = clock.now
        for await update in stream {
            updates.append(update)
        }
        let elapsed = start.duration(to: clock.now).components
        return (updates, Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18)
    }

    private func finishedResult(_ updates: [ScanUpdate]) throws -> ScanResult {
        let finished = updates.compactMap { update -> ScanResult? in
            if case .finished(let result) = update { return result }
            return nil
        }
        XCTAssertEqual(finished.count, 1, "exactly one .finished, got \(finished.count)")
        return try XCTUnwrap(finished.first)
    }

    private func lastProgress(_ updates: [ScanUpdate]) throws -> ScanProgress {
        let progress = updates.compactMap { update -> ScanProgress? in
            if case .progress(let value) = update { return value }
            return nil
        }
        return try XCTUnwrap(progress.last, "no progress updates at all")
    }

    private func progressCount(_ updates: [ScanUpdate]) -> Int {
        updates.filter {
            if case .progress = $0 { return true }
            return false
        }.count
    }

    // MARK: - Concurrency

    func testConcurrentSlowScannersFinishTogether() async throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        let itemA = TestItems.item("A", under: environment.caches, size: 100, category: .applicationCaches)
        let itemB = TestItems.item("B", under: environment.caches, size: 200, category: .browserCaches)
        let itemC = TestItems.item("C", under: environment.logs, size: 300, category: .logs)
        let scanners: [any Cleanora.Scanner] = [
            MockScanner(category: .applicationCaches, result: .produced([itemA]), delay: .milliseconds(400)),
            MockScanner(category: .browserCaches, result: .produced([itemB]), delay: .milliseconds(400)),
            MockScanner(category: .logs, result: .produced([itemC]), delay: .milliseconds(400)),
        ]

        let (updates, duration) = await consume(makeCoordinator(scanners).run())

        // Serial execution would need ≥1.2 s; concurrent must be far below.
        XCTAssertLessThan(duration, 1.0, "scanners did not run concurrently (took \(duration)s)")
        let result = try finishedResult(updates)
        XCTAssertEqual(Set(result.items.map(\.name)), ["A", "B", "C"])
    }

    // MARK: - Cancellation propagation

    func testCancellingConsumerCancelsSlowScanners() async throws {
        let probe = ScanProbe()
        let slowScanner = TrackingScanner(
            category: .applicationCaches,
            probe: probe,
            outcome: .produced([]),
            delay: .seconds(30)
        )
        let coordinator = makeCoordinator([slowScanner])

        let consumer = Task {
            for await _ in coordinator.run() {}
        }
        try await probe.waitUntilStarted()
        consumer.cancel()
        try await Task.sleep(for: .milliseconds(500))

        let finished = await probe.finished
        XCTAssertFalse(finished, "the slow scanner must be cancelled with the stream")
        // The consuming task must unwind promptly instead of hanging.
        await consumer.value
    }

    func testCancelledRunDoesNotEmitFinished() async throws {
        let probe = ScanProbe()
        let slowScanner = TrackingScanner(
            category: .applicationCaches,
            probe: probe,
            outcome: .produced([]),
            delay: .seconds(30)
        )
        let coordinator = makeCoordinator([slowScanner])

        let stream = coordinator.run()
        let consumer = Task {
            var collected: [ScanUpdate] = []
            for await update in stream {
                collected.append(update)
            }
            return collected
        }
        try await probe.waitUntilStarted()
        consumer.cancel()
        let updates = await consumer.value

        XCTAssertFalse(updates.contains { if case .finished = $0 { return true }; return false })
    }

    // MARK: - Throttling

    func testProgressUpdatesThrottledToTenPerSecond() async throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        let probe = ScanProbe()
        let item = TestItems.item("Cache", under: environment.caches, size: 100)
        let spamming = TrackingScanner(
            category: .applicationCaches,
            probe: probe,
            outcome: .produced([item]),
            delay: .seconds(1),
            progressSpam: 2_000,
            progressSpamAfterDelay: 2_000
        )

        let (updates, duration) = await consume(makeCoordinator([spamming]).run())

        // 4 000 progress calls must collapse to ≤ ~10/s of wall time.
        let count = progressCount(updates)
        XCTAssertGreaterThanOrEqual(count, 1, "progress must still be delivered")
        XCTAssertLessThanOrEqual(
            Double(count), duration * 10 + 4,
            "\(count) progress updates in \(duration)s exceeds the 10/s throttle"
        )
        XCTAssertGreaterThanOrEqual(duration, 0.9, "the scanner's work window must have elapsed")
        try finishedResult(updates) // still finishes exactly once
    }

    // MARK: - Failure isolation

    func testPerScannerFailureIsolation() async throws {
        let permissionProbe = ScanProbe()
        let genericProbe = ScanProbe()
        let okItem = TestItems.item("Temp", under: tempRoot, size: 100, category: .temporaryFiles)
        let scanners: [any Cleanora.Scanner] = [
            TrackingScanner(
                category: .applicationCaches,
                probe: permissionProbe,
                outcome: .produced([]),
                failure: .permissionDenied
            ),
            TrackingScanner(
                category: .logs,
                probe: genericProbe,
                outcome: .produced([]),
                failure: .generic
            ),
            MockScanner(category: .temporaryFiles, result: .produced([okItem])),
        ]

        let (updates, _) = await consume(makeCoordinator(scanners).run())

        let states = try lastProgress(updates).states
        XCTAssertEqual(
            states[ScannerKey(id: .applicationCaches)],
            .skipped(.permissionDenied("Application Caches")),
            "NSFileReadNoPermissionError must map to .permissionDenied"
        )
        if case .failed = states[ScannerKey(id: .logs)] {} else {
            XCTFail("generic error must map to .failed, got \(String(describing: states[ScannerKey(id: .logs)]))")
        }
        XCTAssertEqual(states[ScannerKey(id: .temporaryFiles)], .completed(totalBytes: 100, itemCount: 1))

        let result = try finishedResult(updates)
        XCTAssertEqual(result.items.map(\.name), ["Temp"], "the healthy scanner's items must survive")
    }

    func testSkippedScannerReasonSurvivesToProgress() async throws {
        let scanner = MockScanner(
            category: .applicationCaches,
            result: .skipped(.toolNotInstalled("git"))
        )

        let (updates, _) = await consume(makeCoordinator([scanner]).run())

        XCTAssertEqual(
            try lastProgress(updates).states[ScannerKey(id: .applicationCaches)],
            .skipped(.toolNotInstalled("git"))
        )
    }

    // MARK: - Dedup (I8)

    func testOverlappingScannersDeduplicateDeepestPathWins() async throws {
        let caches = environment.caches
        let ancestor = TestItems.item(
            "Google", under: caches, size: 900,
            category: .applicationCaches, method: .trashDirectory
        )
        let deep = TestItems.item(
            "Cache", under: caches.appendingPathComponent("Google/Chrome/Default"),
            size: 400, category: .browserCaches, method: .removeContents
        )
        let scanners: [any Cleanora.Scanner] = [
            MockScanner(category: .applicationCaches, result: .produced([ancestor])),
            MockScanner(category: .browserCaches, result: .produced([deep])),
        ]

        let result = try finishedResult(await consume(makeCoordinator(scanners).run()).updates)

        XCTAssertEqual(result.items.map(\.path.path), [deep.path.path], "ancestor must be dropped, deepest kept")
        XCTAssertEqual(result.totalBytes, 400, "no double counting")
        XCTAssertNil(result.summary(for: .applicationCaches))
        XCTAssertEqual(result.summary(for: .browserCaches)?.itemCount, 1)
    }

    // A large-file finding must NOT shadow its enclosing scanner item —
    // otherwise one big file inside a cache dir makes the whole dir vanish
    // from the results (reviewer finding 1).
    func testLargeFileFindingKeepsEnclosingScannerItem() async throws {
        let cacheDir = environment.caches.appendingPathComponent("com.big/Cache", isDirectory: true)
        let dirItem = TestItems.item("Cache", under: cacheDir.deletingLastPathComponent(), size: 1000)
        let bigFile = CleanupItem(
            name: "big.bin",
            appName: nil,
            category: .largeFiles,
            path: cacheDir.appendingPathComponent("big.bin"),
            size: 900,
            riskLevel: .review,
            reason: "large file",
            deletionMethod: .moveToTrash
        )
        let scanners: [any Cleanora.Scanner] = [
            MockScanner(category: .browserCaches, result: .produced([dirItem])),
            MockScanner(category: .largeFiles, result: .produced([bigFile])),
        ]

        var options = ScanOptions()
        options.enabledCategories = [.browserCaches, .largeFiles]
        let result = try finishedResult(await consume(makeCoordinator(scanners, options: options).run()).updates)

        XCTAssertEqual(result.items.count, 2, "both the directory and the file finding survive")
        XCTAssertTrue(result.items.contains { $0.name == "Cache" }, "enclosing scanner item survives")
        XCTAssertTrue(result.items.contains { $0.category == .largeFiles })
    }

    func testIdenticalPathsCollapseToFirstProducer() async throws {
        let shared = TestItems.item("Same", under: environment.caches, size: 100)
        let duplicate = CleanupItem(
            name: "Same",
            appName: "Same",
            category: .logs,
            path: shared.path,
            size: 200,
            riskLevel: .safe,
            reason: "test fixture",
            deletionMethod: .trashDirectory
        )
        let scanners: [any Cleanora.Scanner] = [
            MockScanner(category: .applicationCaches, result: .produced([shared])),
            MockScanner(category: .logs, result: .produced([duplicate])),
        ]

        let result = try finishedResult(await consume(makeCoordinator(scanners).run()).updates)

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.size, 100)
    }

    func testDeduplicateCollapsesTmpAndPrivateTmpSpellings() {
        let tmp = TestItems.item("X", under: URL(fileURLWithPath: "/tmp"), size: 10)
        let privateTmp = TestItems.item("X", under: URL(fileURLWithPath: "/private/tmp"), size: 20)

        let deduped = ScanCoordinator.deduplicate([tmp, privateTmp])

        XCTAssertEqual(deduped.count, 1, "canonicalization must equate /tmp and /private/tmp")
    }

    // MARK: - Summaries

    func testSummariesSplitPreselectedAndReviewBytes() async throws {
        let caches = environment.caches
        let safe = TestItems.item("Safe", under: caches, size: 1_000)
        let review = CleanupItem(
            name: "Safari",
            appName: "Safari",
            category: .applicationCaches,
            path: caches.appendingPathComponent("com.apple.Safari"),
            size: 500,
            riskLevel: .review,
            reason: "test fixture",
            deletionMethod: .trashDirectory
        )
        let browserReview = CleanupItem(
            name: "Safari",
            appName: "Safari",
            category: .browserCaches,
            path: caches.appendingPathComponent("com.apple.Safari2"),
            size: 700,
            riskLevel: .review,
            reason: "test fixture",
            deletionMethod: .trashDirectory
        )
        let scanners: [any Cleanora.Scanner] = [
            MockScanner(
                category: .applicationCaches,
                result: .produced([safe, review]),
                delay: .zero
            ),
            MockScanner(category: .browserCaches, result: .produced([browserReview])),
        ]

        let result = try finishedResult(await consume(makeCoordinator(scanners).run()).updates)

        let appSummary = try XCTUnwrap(result.summary(for: .applicationCaches))
        XCTAssertEqual(appSummary.totalBytes, 1_500)
        XCTAssertEqual(appSummary.itemCount, 2)
        XCTAssertEqual(appSummary.preselectedBytes, 1_000)
        XCTAssertEqual(appSummary.reviewBytes, 500)
        let browserSummary = try XCTUnwrap(result.summary(for: .browserCaches))
        XCTAssertEqual(browserSummary.preselectedBytes, 0)
        XCTAssertEqual(browserSummary.reviewBytes, 700)
        XCTAssertEqual(result.totalBytes, 2_200)
        XCTAssertEqual(result.selectedItems.map(\.name), ["Safe"])
        XCTAssertEqual(result.selectedBytes, 1_000)
        XCTAssertEqual(result.summaries.map(\.category), [.applicationCaches, .browserCaches], "scan order")
    }

    // MARK: - Disabled categories

    func testDisabledCategoriesAreSkippedAndNeverRun() async throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        let runProbe = ScanProbe()
        let disabledProbe = ScanProbe()
        let item = TestItems.item("Cache", under: environment.caches, size: 100)
        var options = ScanOptions()
        options.enabledCategories = [.applicationCaches]
        let scanners: [any Cleanora.Scanner] = [
            TrackingScanner(category: .applicationCaches, probe: runProbe, outcome: .produced([item])),
            TrackingScanner(category: .trash, probe: disabledProbe, outcome: .produced([])),
        ]

        let (updates, _) = await consume(makeCoordinator(scanners, options: options).run())

        let states = try lastProgress(updates).states
        XCTAssertEqual(states[ScannerKey(id: .trash)], .skipped(.disabledByUser))
        let started = await disabledProbe.started
        XCTAssertFalse(started, "a disabled scanner must not run at all")
        let runFinished = await runProbe.finished
        XCTAssertTrue(runFinished)

        let result = try finishedResult(updates)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.scannerKeys, [ScannerKey(id: .applicationCaches)])
    }

    // MARK: - Result shape

    func testFinishedEmittedExactlyOnceAsLastUpdate() async throws {
        let scanner = MockScanner(category: .applicationCaches, result: .produced([]))

        let (updates, _) = await consume(makeCoordinator([scanner]).run())

        XCTAssertTrue(!updates.isEmpty)
        if case .finished = updates.last! {} else {
            XCTFail("last update must be .finished, got \(String(describing: updates.last))")
        }
        XCTAssertEqual(try finishedResult(updates).items.count, 0)
    }

    func testFreeSpaceBeforeComesFromDiskInfoProvider() async throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        let diskInfo = DiskInfoProvider(volumeURL: tempHome)
        let scanner = MockScanner(category: .applicationCaches, result: .produced([]))

        let result = try finishedResult(
            await consume(makeCoordinator([scanner], diskInfo: diskInfo).run()).updates
        )

        XCTAssertEqual(result.freeSpaceBefore, diskInfo.availableBytes())
        XCTAssertNotNil(result.freeSpaceBefore)
    }

    func testPhaseOneFactoryCoversEveryPhaseOneCategory() {
        let scanners = ScanCoordinator.phaseOneScanners(environment: environment)

        XCTAssertEqual(scanners.count, ScanCategory.phaseOne.count)
        XCTAssertEqual(Set(scanners.map(\.category)), Set(ScanCategory.phaseOne))
        XCTAssertTrue(scanners.allSatisfy(\.isPhaseOne))
    }

    func testFullScannersFactoryAlwaysReturnsTheFullSet() {
        var options = ScanOptions()
        options.includeDeveloperData = false

        let scanners = ScanCoordinator.fullScanners(environment: environment, options: options)

        let categories = Set(scanners.map(\.category))
        XCTAssertTrue(Set(ScanCategory.phaseOne).isSubset(of: categories))
        XCTAssertTrue(categories.contains(.developerData), "developer composite is always present; it self-gates")
        XCTAssertTrue(categories.contains(.largeFiles), "large files are always present; they are informational")
    }

    func testFullScannersFactoryIgnoresDeveloperFlag() {
        var gated = ScanOptions()
        gated.includeDeveloperData = true
        var ungated = ScanOptions()
        ungated.includeDeveloperData = false

        let withGate = ScanCoordinator.fullScanners(environment: environment, options: gated)
        let withoutGate = ScanCoordinator.fullScanners(environment: environment, options: ungated)

        XCTAssertEqual(
            Set(withGate.map(\.category)),
            Set(withoutGate.map(\.category)),
            "the factory is flag-independent: gating lives in enabledCategories and scanner self-gates"
        )
        XCTAssertTrue(Set(ScanCategory.phaseOne).isSubset(of: Set(withGate.map(\.category))))
    }
}
