import XCTest
import os
@testable import Cleanora

/// Write-ahead cleanup logger (task K-04, invariant I9): attempts hit disk
/// (and stay there through a crash) BEFORE the destructive call.
final class CleanupLoggerTests: TempHomeTestCase {
    private var appDirs: AppDirectories!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        appDirs = AppDirectories(home: tempHome)
    }

    private func makeItem(named name: String = "Chrome Cache") -> CleanupItem {
        CleanupItem(
            name: name,
            category: .browserCaches,
            path: tempHome.appendingPathComponent("Library/Caches/\(name)"),
            size: 1024,
            riskLevel: .safe,
            reason: "test",
            deletionMethod: .removeContents
        )
    }

    private func makeOutcome(for item: CleanupItem, status: ItemOutcome.Status = .removed) -> ItemOutcome {
        ItemOutcome(
            itemID: item.id, name: item.name, category: item.category,
            path: item.path.path, status: status, bytesFreed: 512
        )
    }

    private func logFileNames() throws -> [String] {
        guard fileManager.fileExists(atPath: appDirs.logsDirectory.path) else { return [] }
        return try fileManager.contentsOfDirectory(atPath: appDirs.logsDirectory.path).sorted()
    }

    func testAttemptThenResultRoundTripInOrder() {
        let logger = CleanupLogger(appDirs: appDirs)
        let item = makeItem()
        logger.appendAttempt(item)
        logger.appendResult(makeOutcome(for: item))

        let entries = logger.readCurrentLog()
        XCTAssertEqual(entries.count, 2)
        guard case .attempt(let itemID, let name, let path, _) = entries.first else {
            return XCTFail("first entry must be the attempt, got \(String(describing: entries.first))")
        }
        XCTAssertEqual(itemID, item.id)
        XCTAssertEqual(name, item.name)
        XCTAssertEqual(path, item.path.path)
        guard case .result(let resultID, let status, let bytesFreed, _) = entries.last else {
            return XCTFail("second entry must be the result, got \(String(describing: entries.last))")
        }
        XCTAssertEqual(resultID, item.id)
        XCTAssertEqual(status, ItemOutcome.Status.removed)
        XCTAssertEqual(bytesFreed, 512)
    }

    // I9 durability: the bytes must be readable back from a fresh handle the
    // moment appendAttempt returns (fsync before the destructive call).
    func testAttemptIsDurableOnDiskBeforeAppendReturns() throws {
        let logger = CleanupLogger(appDirs: appDirs)
        let item = makeItem()
        logger.appendAttempt(item)

        let url = try XCTUnwrap(logger.currentLogURL, "attempt must have created today's log")
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains(item.id.uuidString),
                      "WAL line for the item must already be on disk")
        XCTAssertEqual(raw.split(separator: "\n").count, 1, "one JSONL entry per line")
    }

    func testLogFileIsNamedCleanupWithISO8601Timestamp() throws {
        let logger = CleanupLogger(appDirs: appDirs)
        logger.appendAttempt(makeItem())
        let url = try XCTUnwrap(logger.currentLogURL)
        let pattern = "^cleanup-\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z\\.jsonl$"
        XCTAssertNotNil(
            url.lastPathComponent.range(of: pattern, options: .regularExpression),
            "unexpected log file name: \(url.lastPathComponent)"
        )
    }

    // Tolerant read: one corrupt line must not lose the valid entries.
    func testReadCurrentLogSkipsCorruptLines() throws {
        let logger = CleanupLogger(appDirs: appDirs)
        let item = makeItem()
        logger.appendAttempt(item)

        let url = try XCTUnwrap(logger.currentLogURL)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("this is not json {{{\n".utf8))
        try handle.close()

        logger.appendResult(makeOutcome(for: item))
        XCTAssertEqual(logger.readCurrentLog().count, 2)
    }

    // A relaunch mid-day must keep appending to today's file.
    func testSameDayAppendsReuseTodaysFile() throws {
        let noon = day(year: 2026, month: 9, dayOfMonth: 12, hour: 12)
        let clock = OSAllocatedUnfairLock(initialState: noon)
        let logger = CleanupLogger(appDirs: appDirs, clock: { clock.withLock { $0 } })

        logger.appendAttempt(makeItem(named: "A"))
        let firstURL = try XCTUnwrap(logger.currentLogURL)
        let evening = day(year: 2026, month: 9, dayOfMonth: 12, hour: 18)
        clock.withLock { $0 = evening }
        logger.appendAttempt(makeItem(named: "B"))

        XCTAssertEqual(logger.currentLogURL, firstURL, "same day = same file")
        XCTAssertEqual(try logFileNames().count, 1)
        XCTAssertEqual(logger.readCurrentLog().count, 2)
    }

    func testDayRolloverStartsNewFile() throws {
        let clock = OSAllocatedUnfairLock(initialState: day(year: 2026, month: 9, dayOfMonth: 12, hour: 23))
        let logger = CleanupLogger(appDirs: appDirs, clock: { clock.withLock { $0 } })

        logger.appendAttempt(makeItem(named: "A"))
        let firstURL = try XCTUnwrap(logger.currentLogURL)
        let nextMorning = day(year: 2026, month: 9, dayOfMonth: 13, hour: 1)
        clock.withLock { $0 = nextMorning }
        logger.appendResult(makeOutcome(for: makeItem(named: "A")))

        let secondURL = try XCTUnwrap(logger.currentLogURL)
        XCTAssertNotEqual(secondURL, firstURL, "a new day starts a fresh WAL file")
        XCTAssertEqual(try logFileNames().count, 2)
        XCTAssertEqual(logger.readCurrentLog().count, 1, "readCurrentLog covers today's file only")
    }

    // Appends come from the cleanup task and (potentially) log readers —
    // the internal lock must serialize them without losing a line.
    func testConcurrentAppendsAllPersist() async {
        let logger = CleanupLogger(appDirs: appDirs)
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<8 {
                group.addTask {
                    for fileIndex in 0..<5 {
                        logger.appendAttempt(CleanupItem(
                            name: "w\(writer)-f\(fileIndex)",
                            category: .applicationCaches,
                            path: URL(fileURLWithPath: "/tmp/w\(writer)-f\(fileIndex)"),
                            size: 1, riskLevel: .safe, reason: "test",
                            deletionMethod: .removeContents
                        ))
                    }
                }
            }
        }
        XCTAssertEqual(logger.readCurrentLog().count, 40)
    }

    func testEmptyStateHasNoLogAndNoEntries() {
        let logger = CleanupLogger(appDirs: appDirs)
        XCTAssertNil(logger.currentLogURL)
        XCTAssertEqual(logger.readCurrentLog(), [])
    }

    private func day(year: Int, month: Int, dayOfMonth: Int, hour: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayOfMonth
        components.hour = hour
        return Calendar.current.date(from: components)!
    }
}
