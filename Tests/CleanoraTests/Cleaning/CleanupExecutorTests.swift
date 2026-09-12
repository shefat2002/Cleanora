import XCTest
import os
@testable import Cleanora

/// CleanupExecutor (task K-03): the runtime around the gate — I9 WAL before
/// deletion, measured bytesFreed, I11 failure isolation, I12 cancellation
/// between items, free-space floor.
final class CleanupExecutorTests: TempHomeTestCase {
    private var appDirs: AppDirectories!
    private var logger: CleanupLogger!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        appDirs = AppDirectories(home: tempHome)
        logger = CleanupLogger(appDirs: appDirs)
    }

    // MARK: - Helpers

    private func makeItem(
        name: String,
        path: URL,
        method: DeletionMethod = .removeContents,
        risk: RiskLevel = .safe,
        selected: Bool = true,
        confirmation: CleanupItem.ConfirmationLevel = .standard,
        category: ScanCategory = .applicationCaches,
        estimatedSize: Int64 = 0
    ) -> CleanupItem {
        CleanupItem(
            name: name,
            category: category,
            path: path,
            size: estimatedSize,
            riskLevel: risk,
            selected: selected,
            reason: "test",
            deletionMethod: method,
            confirmationLevel: confirmation
        )
    }

    private func cacheDir(named name: String, files: [(String, Int)]) throws -> URL {
        let dir = tempHome.appendingPathComponent("Library/Caches/\(name)")
        try FixtureBuilder.makeTree(in: dir, files)
        return dir
    }

    private func makeExecutor(
        deletion: DeletionMethodExecutor = DeletionMethodExecutor(),
        freeSpace: @escaping @Sendable () -> Int64? = { nil }
    ) -> CleanupExecutor {
        CleanupExecutor(
            policy: SafetyPolicy.standard(home: tempHome, tempRoot: tempRoot),
            logger: logger,
            environment: environment,
            deletion: deletion,
            freeSpace: freeSpace
        )
    }

    /// Stands in for FileManager.trashItem (which always targets the REAL
    /// user Trash — never callable from tests). Optionally gates the move so
    /// tests can hold the executor between validate/attempt and deletion.
    private func fixtureTrashExecutor(
        gate: DispatchSemaphore? = nil,
        settleDelay: TimeInterval = 0,
        throwsForAll: Bool = false,
        onCall: (@Sendable (URL) -> Void)? = nil
    ) -> DeletionMethodExecutor {
        let destinationRoot = tempHome.appendingPathComponent(".Trash", isDirectory: true)
        return DeletionMethodExecutor(trashMove: { url in
            onCall?(url)
            gate?.wait()
            if settleDelay > 0 { Thread.sleep(forTimeInterval: settleDelay) }
            if throwsForAll {
                throw NSError(
                    domain: "CleanoraTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "trash refused"]
                )
            }
            let destination = destinationRoot.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
    }

    private func collect(_ stream: AsyncStream<CleanupEvent>) async -> [CleanupEvent] {
        var events: [CleanupEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    @discardableResult
    private func waitUpTo(_ seconds: Double, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    private func status(_ outcome: ItemOutcome) -> ItemOutcome.Status { outcome.status }

    /// bytesFreed is measured in ALLOCATED bytes (block-rounded, matching the
    /// scan pipeline). Expectations are captured with the same probe the
    /// executor uses, so assertions stay exact without hardcoding blocks.
    private let probe = ContentSizeProbe()

    private func measureBefore(_ url: URL) -> Int64 {
        probe.logicalBytes(at: url) ?? 0
    }

    // MARK: - Happy path + measured bytes

    // bytesFreed is MEASURED (before − after re-stat), never the estimate.
    func testRemoveContentsFreesMeasuredBytesAndEmitsProgressThenFinished() async throws {
        let dir = try cacheDir(named: "com.example.app", files: [
            ("a.dat", 100), ("b.dat", 200), ("sub/c.dat", 300),
        ])
        let item = makeItem(name: "Example", path: dir, estimatedSize: 99_999)
        let expectedBytes = measureBefore(dir)

        let events = await collect(makeExecutor().run(
            items: [item], confirmed: [item.id], destructiveConfirmed: false
        ))

        XCTAssertEqual(events.count, 2)
        guard case .progress(let progress) = events[0] else {
            return XCTFail("expected a progress event first, got \(events[0])")
        }
        XCTAssertEqual(progress.currentItem?.id, item.id)
        XCTAssertEqual(progress.outcomes.count, 0)
        guard case .finished(let report) = events[1] else {
            return XCTFail("expected a finished event last, got \(events[1])")
        }
        XCTAssertEqual(report.outcomes.count, 1)
        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertEqual(status(outcome), .removed)
        XCTAssertEqual(outcome.bytesFreed, expectedBytes, "allocated bytes, measured")
        XCTAssertEqual(report.bytesFreed, expectedBytes)
        XCTAssertEqual(report.itemsRemoved, 1)
        XCTAssertNil(report.freeSpaceBefore, "unknown free space stays nil")
        XCTAssertFalse(fileManager.fileExists(atPath: dir.appendingPathComponent("a.dat").path))
        XCTAssertTrue(fileManager.fileExists(atPath: dir.path))
    }

    func testTrashMethodMovesToTrashAndReportsMeasuredBytes() async throws {
        let logs = tempHome.appendingPathComponent("Library/Logs")
        try FixtureBuilder.makeTree(in: logs, [("app.log", 250)])
        let file = logs.appendingPathComponent("app.log")
        let expectedBytes = measureBefore(file)
        let item = makeItem(
            name: "Old log", path: file, method: .moveToTrash,
            risk: .review, estimatedSize: 1
        )

        let events = await collect(makeExecutor(
            deletion: fixtureTrashExecutor()
        ).run(items: [item], confirmed: [item.id], destructiveConfirmed: false))

        guard case .finished(let report) = events.last else {
            return XCTFail("expected a finished event, got \(String(describing: events.last))")
        }
        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertEqual(status(outcome), .removed)
        XCTAssertEqual(outcome.bytesFreed, expectedBytes, "measured, not the estimate")
        XCTAssertFalse(fileManager.fileExists(atPath: file.path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: tempHome.appendingPathComponent(".Trash/app.log").path
        ))
    }

    // Emptying the Trash: destructive confirmation, in-place content removal.
    func testTrashEmptyingWithDestructiveConfirmRemovesContentsInPlace() async throws {
        let trash = tempHome.appendingPathComponent(".Trash", isDirectory: true)
        try FixtureBuilder.makeTree(in: trash, [("t1.dat", 100), ("t2.dat", 40)])
        let expectedBytes = measureBefore(trash)
        let item = makeItem(
            name: "Trash", path: trash,
            confirmation: .destructive, category: .trash, estimatedSize: 140
        )

        let events = await collect(makeExecutor().run(
            items: [item], confirmed: [item.id], destructiveConfirmed: true
        ))

        guard case .finished(let report) = events.last else {
            return XCTFail("expected a finished event")
        }
        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertEqual(status(outcome), .removed)
        XCTAssertEqual(outcome.bytesFreed, expectedBytes)
        XCTAssertTrue(fileManager.fileExists(atPath: trash.path),
                      ".Trash itself must survive being emptied")
        XCTAssertFalse(fileManager.fileExists(atPath: trash.appendingPathComponent("t1.dat").path))
    }

    // MARK: - Isolation + cancellation

    // I11: a failing item must not abort the batch.
    func testFailureIsolatesItems() async throws {
        let first = try cacheDir(named: "first", files: [("f.dat", 100)])
        let secondFile = tempHome.appendingPathComponent("Library/Caches/stuck.dat")
        let third = try cacheDir(named: "third", files: [("f.dat", 300)])
        let expectedBytes = measureBefore(first) + measureBefore(third)
        try FixtureBuilder.makeTree(
            in: secondFile.deletingLastPathComponent(), [("stuck.dat", 250)]
        )
        let trashItem = makeItem(
            name: "stuck", path: secondFile, method: .moveToTrash,
            risk: .review, estimatedSize: 250
        )
        let items = [
            makeItem(name: "first", path: first),
            trashItem,
            makeItem(name: "third", path: third),
        ]

        let events = await collect(makeExecutor(
            deletion: fixtureTrashExecutor(throwsForAll: true)
        ).run(items: items, confirmed: Set(items.map(\.id)), destructiveConfirmed: false))

        guard case .finished(let report) = events.last else {
            return XCTFail("expected a finished event")
        }
        XCTAssertEqual(report.outcomes.count, 3)
        XCTAssertEqual(report.itemsRemoved, 2)
        XCTAssertEqual(report.failureCount, 1)
        XCTAssertEqual(report.bytesFreed, expectedBytes, "first + third; the failed item frees nothing")
        XCTAssertEqual(report.freedBytes(in: .applicationCaches), expectedBytes)
        XCTAssertTrue(fileManager.fileExists(atPath: secondFile.path),
                      "failed item must be left untouched")
    }

    // I12: cancel leaves every remaining item untouched.
    func testCancellationBetweenItemsLeavesRemainderUntouched() async throws {
        let first = try cacheDir(named: "first", files: [("f.dat", 100)])
        let second = try cacheDir(named: "second", files: [("f.dat", 200)])
        let third = try cacheDir(named: "third", files: [("f.dat", 300)])
        let trashItem = makeItem(
            name: "first-trash", path: first, method: .moveToTrash,
            risk: .review, estimatedSize: 100
        )
        let items = [
            trashItem,
            makeItem(name: "second", path: second),
            makeItem(name: "third", path: third),
        ]

        let gate = DispatchSemaphore(value: 0)
        let attemptSeen = OSAllocatedUnfairLock(initialState: false)
        let executor = makeExecutor(deletion: fixtureTrashExecutor(
            gate: gate, settleDelay: 0.3,
            onCall: { _ in attemptSeen.withLock { $0 = true } }
        ))
        let stream = executor.run(
            items: items, confirmed: Set(items.map(\.id)), destructiveConfirmed: false
        )

        let consumerDone = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            var collected: [CleanupEvent] = []
            for await event in stream {
                collected.append(event)
            }
            consumerDone.withLock { $0 = true }
            return collected
        }

        // Hold the producer between "attempt logged" and "delete first item".
        XCTAssertTrue(waitUpTo(5) { attemptSeen.withLock { $0 } },
                      "executor never reached the first deletion")
        task.cancel()
        XCTAssertTrue(waitUpTo(5) { consumerDone.withLock { $0 } })
        gate.signal()
        let events = await task.value

        // Let the producer wind down item 1 and observe the cancellation.
        XCTAssertTrue(waitUpTo(5) {
            logger.readCurrentLog().contains { entry in
                if case .result(let id, _, _, _) = entry { return id == trashItem.id }
                return false
            }
        })

        XCTAssertEqual(logger.readCurrentLog().filter {
            if case .attempt = $0 { return true }
            return false
        }.count, 1, "only item 1 ever reached an attempt")

        XCTAssertFalse(fileManager.fileExists(atPath: first.appendingPathComponent("f.dat").path),
                       "item 1 was already in flight")
        XCTAssertTrue(fileManager.fileExists(atPath: second.appendingPathComponent("f.dat").path),
                      "item 2 must be untouched after cancellation")
        XCTAssertTrue(fileManager.fileExists(atPath: third.appendingPathComponent("f.dat").path),
                      "item 3 must be untouched after cancellation")
        XCTAssertTrue(events.count <= 2, "cancelled consumer sees at most item 1's events")
    }

    // MARK: - Free-space floor

    func testFreeSpaceFloorRefusesWholeBatchWithoutDeleting() async throws {
        let first = try cacheDir(named: "first", files: [("f.dat", 100)])
        let second = try cacheDir(named: "second", files: [("f.dat", 200)])
        let items = [
            makeItem(name: "first", path: first, estimatedSize: 100),
            makeItem(name: "second", path: second, estimatedSize: 200),
        ]

        let events = await collect(makeExecutor(freeSpace: { 1_000_000 }).run(
            items: items, confirmed: Set(items.map(\.id)), destructiveConfirmed: false
        ))

        XCTAssertEqual(events.count, 1, "refusal emits finished only — nothing was attempted")
        guard case .finished(let report) = events[0] else {
            return XCTFail("expected a finished event")
        }
        XCTAssertEqual(report.outcomes.count, 2)
        XCTAssertTrue(report.outcomes.allSatisfy { $0.status == .skipped })
        XCTAssertTrue(report.outcomes.allSatisfy {
            $0.message?.localizedCaseInsensitiveContains("free space") == true
        })
        XCTAssertEqual(report.freeSpaceBefore, 1_000_000)
        XCTAssertEqual(report.bytesFreed, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: first.appendingPathComponent("f.dat").path))
        XCTAssertTrue(fileManager.fileExists(atPath: second.appendingPathComponent("f.dat").path))
    }

    // The floor is max(2 GB, selectedBytes) — a 5 GB batch on a 5 GB disk is
    // refused even though it clears the 2 GB floor.
    func testFreeSpaceFloorAlsoCoversSelectedBytes() async throws {
        let dir = try cacheDir(named: "big", files: [("f.dat", 100)])
        let item = makeItem(name: "big", path: dir, estimatedSize: 6_000_000_000)

        let events = await collect(makeExecutor(freeSpace: { 5_000_000_000 }).run(
            items: [item], confirmed: [item.id], destructiveConfirmed: false
        ))

        guard case .finished(let report) = events.last else {
            return XCTFail("expected a finished event")
        }
        XCTAssertTrue(report.outcomes.allSatisfy { $0.status == .skipped })
        XCTAssertTrue(fileManager.fileExists(atPath: dir.appendingPathComponent("f.dat").path))
    }

    func testUnknownFreeSpaceSkipsFloorCheckAndProceeds() async throws {
        let dir = try cacheDir(named: "first", files: [("f.dat", 100)])
        let item = makeItem(name: "first", path: dir, estimatedSize: 100)

        let events = await collect(makeExecutor(freeSpace: { nil }).run(
            items: [item], confirmed: [item.id], destructiveConfirmed: false
        ))

        guard case .finished(let report) = events.last else {
            return XCTFail("expected a finished event")
        }
        XCTAssertEqual(report.outcomes.first.map(status), .removed)
        XCTAssertNil(report.freeSpaceBefore)
        XCTAssertNil(report.freeSpaceAfter)
    }

    func testReportCarriesFreeSpaceFromProviderAndEmptyBatchFinishesOnce() async throws {
        let readings = OSAllocatedUnfairLock<[Int64?]>(initialState: [10_000_000_000, 9_000_000_000])
        let executor = makeExecutor(freeSpace: {
            readings.withLock { state -> Int64? in
                state.isEmpty ? nil : state.removeFirst()
            }
        })

        let item = makeItem(
            name: "ghost",
            path: tempHome.appendingPathComponent("Library/Caches/never-created"),
            estimatedSize: 10
        )
        let events = await collect(executor.run(
            items: [item], confirmed: [item.id], destructiveConfirmed: false
        ))
        guard case .finished(let report) = events.last else {
            return XCTFail("expected a finished event")
        }
        XCTAssertEqual(report.freeSpaceBefore, 10_000_000_000)
        XCTAssertEqual(report.freeSpaceAfter, 9_000_000_000)

        // Empty batch: exactly one finished event, nothing else.
        let empty = await collect(executor.run(items: [], confirmed: [], destructiveConfirmed: false))
        XCTAssertEqual(empty.count, 1)
        guard case .finished(let emptyReport) = empty[0] else {
            return XCTFail("expected a finished event")
        }
        XCTAssertEqual(emptyReport.outcomes, [])
    }

    // MARK: - Gate at runtime (defense in depth behind SafetyPolicy)

    func testGateRejectionsAreSkippedWithoutTouchingTheFilesystem() async throws {
        let valid = try cacheDir(named: "valid", files: [("f.dat", 100)])
        let unconfirmed = try cacheDir(named: "unconfirmed", files: [("f.dat", 100)])
        let destructive = try cacheDir(named: "destructive", files: [("f.dat", 100)])
        let items = [
            makeItem(name: "unconfirmed", path: unconfirmed),
            makeItem(name: "outside", path: tempHome.appendingPathComponent("Documents/report.pdf"),
                     method: .moveToTrash, risk: .review),
            makeItem(name: "destructive", path: destructive, confirmation: .destructive),
            makeItem(name: "valid", path: valid),
        ]
        let confirmed: Set<UUID> = [items[1].id, items[2].id, items[3].id]

        let events = await collect(makeExecutor().run(
            items: items, confirmed: confirmed, destructiveConfirmed: false
        ))

        guard case .finished(let report) = events.last else {
            return XCTFail("expected a finished event")
        }
        XCTAssertEqual(report.outcomes.map(status), [.skipped, .skipped, .skipped, .removed])
        XCTAssertEqual(report.failureCount, 0, "gate rejections are refusals, not failures")
        XCTAssertTrue(fileManager.fileExists(atPath: unconfirmed.appendingPathComponent("f.dat").path))
        XCTAssertTrue(fileManager.fileExists(atPath: destructive.appendingPathComponent("f.dat").path))
        XCTAssertTrue(fileManager.fileExists(atPath: valid.path),
                      "the removed item's cache root survives a content wipe")
        // "outside" points into Documents (blocked) — nothing was created or removed there.
        XCTAssertFalse(fileManager.fileExists(atPath: tempHome.appendingPathComponent("Documents").path))
    }

    // I9: at the moment the destructive call begins, the attempt is already
    // durable on disk.
    func testAttemptIsOnDiskBeforeDeletionBegins() async throws {
        let first = try cacheDir(named: "first", files: [("f.dat", 100)])
        let trashItem = makeItem(
            name: "first", path: first, method: .moveToTrash,
            risk: .review, estimatedSize: 100
        )
        let walAtDeleteTime = OSAllocatedUnfairLock<[LogEntry]?>(initialState: nil)
        let executor = makeExecutor(deletion: fixtureTrashExecutor(onCall: { [logger] _ in
            walAtDeleteTime.withLock { $0 = logger.readCurrentLog() }
        }))

        let events = await collect(executor.run(
            items: [trashItem], confirmed: [trashItem.id], destructiveConfirmed: false
        ))

        guard case .finished(let report) = events.last else {
            return XCTFail("expected a finished event")
        }
        XCTAssertEqual(report.outcomes.first.map(status), .removed)
        let snapshot = try XCTUnwrap(
            walAtDeleteTime.withLock { $0 },
            "the trash move was never invoked"
        )
        XCTAssertTrue(snapshot.contains { entry in
            if case .attempt(let id, _, _, _) = entry { return id == trashItem.id }
            return false
        }, "attempt must be in the WAL before the destructive call runs")
        XCTAssertEqual(logger.readCurrentLog().count, 2, "attempt + result")
    }

    // The WAL is the safety net — if it cannot be written, nothing is deleted.
    func testUnwritableCleanupLogBlocksDeletion() async throws {
        try fileManager.createDirectory(at: appDirs.logsDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: appDirs.logsDirectory.path
        )
        defer {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: appDirs.logsDirectory.path
            )
        }

        let dir = try cacheDir(named: "guarded", files: [("f.dat", 100)])
        let item = makeItem(name: "guarded", path: dir)

        let events = await collect(makeExecutor().run(
            items: [item], confirmed: [item.id], destructiveConfirmed: false
        ))

        guard case .finished(let report) = events.last else {
            return XCTFail("expected a finished event")
        }
        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertEqual(status(outcome), .failed)
        XCTAssertTrue(fileManager.fileExists(atPath: dir.appendingPathComponent("f.dat").path),
                      "no durable WAL record means no deletion")
        XCTAssertEqual(report.bytesFreed, 0)
    }

    // A partially-removed item is reported as partial, with only the removed
    // bytes counted.
    func testPartialStatusWhenSomeChildrenRemain() async throws {
        let dir = try cacheDir(named: "partial", files: [("gone.dat", 100), ("locked/stuck.dat", 64)])
        let locked = dir.appendingPathComponent("locked")
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        let item = makeItem(name: "partial", path: dir)
        let removedChildBytes = measureBefore(dir.appendingPathComponent("gone.dat"))

        let events = await collect(makeExecutor().run(
            items: [item], confirmed: [item.id], destructiveConfirmed: false
        ))

        guard case .finished(let report) = events.last else {
            return XCTFail("expected a finished event")
        }
        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertEqual(status(outcome), .partial)
        XCTAssertEqual(outcome.bytesFreed, removedChildBytes, "only the removed child's bytes")
        XCTAssertEqual(report.itemsRemoved, 0)
        XCTAssertEqual(report.partiallyRemoved, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: locked.appendingPathComponent("stuck.dat").path))
    }

    // Trash empties FIRST in a mixed batch: a recoverable item moved to
    // ~/.Trash later must not be destroyed by this run's trash-emptying.
    func testTrashEmptiedBeforeRecoverableItemsMoveIntoIt() async throws {
        let trashDir = tempHome.appendingPathComponent(".Trash")
        try Data("old".utf8).write(to: trashDir.appendingPathComponent("old.txt"))

        let logDir = tempHome.appendingPathComponent("Library/Logs/app-logs")
        try FixtureBuilder.makeTree(in: logDir, [("app.log", 100)])
        let logItem = makeItem(
            name: "app-logs", path: logDir, method: .moveToTrash, category: .logs
        )
        let trashItem = makeItem(
            name: "Trash", path: trashDir,
            confirmation: .destructive, category: .trash
        )

        // Log item deliberately FIRST in the submitted order — the executor
        // must reorder trash-emptying ahead of it.
        let events = await collect(makeExecutor(deletion: fixtureTrashExecutor()).run(
            items: [logItem, trashItem],
            confirmed: [logItem.id, trashItem.id],
            destructiveConfirmed: true
        ))

        guard case .finished(let report) = events.last else {
            return XCTFail("expected a finished event")
        }
        let statuses: [ItemOutcome.Status] = report.outcomes.map(\.status)
        XCTAssertEqual(statuses, [.removed, .removed])
        XCTAssertFalse(
            fileManager.fileExists(atPath: trashDir.appendingPathComponent("old.txt").path),
            "pre-existing trash content must be emptied"
        )
        XCTAssertTrue(
            fileManager.fileExists(atPath: trashDir.appendingPathComponent("app-logs").path),
            "recoverable item moved AFTER emptying stays in the Trash"
        )
    }
}
