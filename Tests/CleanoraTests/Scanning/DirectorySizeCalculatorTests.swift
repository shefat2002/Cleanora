import XCTest
import os
@testable import Cleanora

/// E-02 — DirectorySizeCalculator.
/// Covers the fixture math, allocated (not logical) sizes, invariant I7
/// (symlinks never followed), unreadable-directory tolerance, cancellation,
/// time budget and the bounded concurrency limit.
final class DirectorySizeCalculatorTests: TempHomeTestCase {
    private let calculator = DirectorySizeCalculator()
    private let fileManager = FileManager.default

    // MARK: - Helpers

    private func allocatedBytes(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        if let allocated = values?.totalFileAllocatedSize { return Int64(allocated) }
        if let logical = values?.fileSize { return Int64(logical) }
        return 0
    }

    /// 3-level fixture: 3 × 10 000 logical bytes.
    @discardableResult
    private func makeThreeLevelTree() throws -> (root: URL, files: [URL]) {
        let root = tempHome.appendingPathComponent("tree", isDirectory: true)
        try FixtureBuilder.makeTree(in: root, [
            ("a.txt", 10_000),
            ("level1/mid.txt", 10_000),
            ("level1/level2/leaf.txt", 10_000),
        ])
        return (
            root,
            [
                root.appendingPathComponent("a.txt"),
                root.appendingPathComponent("level1/mid.txt"),
                root.appendingPathComponent("level1/level2/leaf.txt"),
            ]
        )
    }

    // MARK: - Measurement

    func testMeasuresThreeLevelFixtureBytesAndFileCount() async throws {
        let (root, files) = try makeThreeLevelTree()

        let result = await calculator.measure(at: root)

        XCTAssertEqual(result.fileCount, 3)
        let expectedBytes = files.map { allocatedBytes(of: $0) }.reduce(0, +)
        XCTAssertEqual(result.bytes, expectedBytes)
        // Allocated size never under-reports the logical content size.
        XCTAssertGreaterThanOrEqual(result.bytes, 30_000)
    }

    func testReportsAllocatedSizeNotLogicalSize() async throws {
        let root = tempHome.appendingPathComponent("alloc", isDirectory: true)
        let file = try FixtureBuilder.makeTree(in: root, [("single.bin", 10_000)])
            .appendingPathComponent("single.bin")

        let result = await calculator.measure(at: root)

        // Block-rounded allocation, matching .totalFileAllocatedSizeKey exactly.
        XCTAssertEqual(result.bytes, allocatedBytes(of: file))
        XCTAssertGreaterThanOrEqual(result.bytes, 10_000)
        XCTAssertEqual(result.fileCount, 1)
    }

    func testEmptyDirectoryMeasuresZero() async throws {
        let root = tempHome.appendingPathComponent("empty", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let result = await calculator.measure(at: root)

        XCTAssertEqual(result.bytes, 0)
        XCTAssertEqual(result.fileCount, 0)
    }

    // MARK: - I7: symlinks are never followed

    func testSymlinkToFileOutsideFixtureIsNotFollowed() async throws {
        // Target lives OUTSIDE the measured fixture tree entirely.
        let outsideFile = tempRoot.appendingPathComponent("outside-target.bin")
        try Data(repeating: 0x42, count: 200_000).write(to: outsideFile)

        let root = tempHome.appendingPathComponent("tree", isDirectory: true)
        try FixtureBuilder.makeTree(in: root, [("real.txt", 1_000)])
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("link.bin"),
            withDestinationURL: outsideFile
        )

        let result = await calculator.measure(at: root)

        XCTAssertEqual(result.fileCount, 1)
        XCTAssertEqual(result.bytes, allocatedBytes(of: root.appendingPathComponent("real.txt")))
        // The target must be untouched — merely read, never written or removed.
        XCTAssertTrue(fileManager.fileExists(atPath: outsideFile.path))
        XCTAssertGreaterThanOrEqual(allocatedBytes(of: outsideFile), 200_000)
    }

    func testSymlinkedDirectoryOutsideFixtureIsNotDescended() async throws {
        let outsideDir = tempRoot.appendingPathComponent("outside-dir", isDirectory: true)
        try FixtureBuilder.makeTree(in: outsideDir, [("heavy.bin", 300_000)])

        let root = tempHome.appendingPathComponent("tree", isDirectory: true)
        try FixtureBuilder.makeTree(in: root, [("real.txt", 1_000)])
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("linked-dir"),
            withDestinationURL: outsideDir
        )

        let result = await calculator.measure(at: root)

        XCTAssertEqual(result.fileCount, 1)
        XCTAssertEqual(result.bytes, allocatedBytes(of: root.appendingPathComponent("real.txt")))
        XCTAssertTrue(fileManager.fileExists(atPath: outsideDir.appendingPathComponent("heavy.bin").path))
    }

    // MARK: - Unreadable directories are skipped, not fatal

    func testUnreadableSubdirectoryIsSkippedNotFatal() async throws {
        try XCTSkipUnless(getuid() != 0, "chmod-based unreadability does not apply to root")
        let root = tempHome.appendingPathComponent("tree", isDirectory: true)
        try FixtureBuilder.makeTree(in: root, [
            ("ok.txt", 1_000),
            ("locked/secret.bin", 50_000),
        ])
        let locked = root.appendingPathComponent("locked")
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let result = await calculator.measure(at: root)

        XCTAssertEqual(result.fileCount, 1)
        XCTAssertEqual(result.bytes, allocatedBytes(of: root.appendingPathComponent("ok.txt")))
    }

    // MARK: - Time budget

    func testZeroTimeBudgetReportsHitBudgetWithoutWork() async throws {
        let (root, _) = try makeThreeLevelTree()

        let result = await calculator.measure(at: root, timeBudget: 0)

        XCTAssertTrue(result.hitTimeBudget)
        XCTAssertEqual(result.fileCount, 0)
        XCTAssertEqual(result.bytes, 0)
    }

    func testGenerousTimeBudgetDoesNotReportHitBudget() async throws {
        let (root, _) = try makeThreeLevelTree()

        let result = await calculator.measure(at: root, timeBudget: 60)

        XCTAssertFalse(result.hitTimeBudget)
        XCTAssertEqual(result.fileCount, 3)
    }

    // MARK: - Cancellation

    func testCancelledTaskStopsTraversalEarly() async throws {
        // Wide enough that a full traversal cannot finish before the
        // cancellation lands.
        let root = tempHome.appendingPathComponent("wide", isDirectory: true)
        var entries: [(String, Int)] = []
        for index in 0..<4_000 {
            entries.append(("dir-\(String(format: "%04d", index))/file.bin", 1))
        }
        try FixtureBuilder.makeTree(in: root, entries)
        let totalFiles = entries.count

        // Local binding so the detached closure never captures the test case.
        let calculator = DirectorySizeCalculator()
        let task = Task { await calculator.measure(at: root) }
        task.cancel()
        let result = await task.value

        XCTAssertLessThan(result.fileCount, totalFiles, "cancelled traversal must not report the full tree")
    }

    func testShouldContinuePredicateStopsExpansionDeterministically() async throws {
        let root = tempHome.appendingPathComponent("wide", isDirectory: true)
        var entries: [(String, Int)] = []
        for index in 0..<50 {
            entries.append(("dir-\(String(format: "%02d", index))/file.bin", 1))
        }
        try FixtureBuilder.makeTree(in: root, entries)
        let gate = TestGate(allowedCalls: 2)

        let result = await calculator.measure(at: root, shouldContinue: { gate.keepGoing() })

        XCTAssertGreaterThan(result.fileCount, 0)
        XCTAssertLessThan(result.fileCount, entries.count)
        XCTAssertEqual(result.hitTimeBudget, false)
    }

    func testShouldContinueFalseFromStartYieldsEmptyResult() async throws {
        let (root, _) = try makeThreeLevelTree()

        let result = await calculator.measure(at: root, shouldContinue: { false })

        XCTAssertEqual(result, DirectorySizeCalculator.Result())
    }

    // MARK: - Bounded concurrency

    func testConcurrencyLimitIsBoundedByMinEightAndTwiceCores() {
        let expected = min(8, ProcessInfo.processInfo.activeProcessorCount * 2)
        XCTAssertEqual(DirectorySizeCalculator.maximumConcurrentDirectories, expected)
        XCTAssertGreaterThanOrEqual(DirectorySizeCalculator.maximumConcurrentDirectories, 1)
        XCTAssertLessThanOrEqual(DirectorySizeCalculator.maximumConcurrentDirectories, 8)
    }
}

/// Thread-safe on/off gate used to drive `shouldContinue` deterministically.
final class TestGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    private let allowedCalls: Int

    init(allowedCalls: Int) {
        self.allowedCalls = allowedCalls
    }

    /// Returns true for the first `allowedCalls` invocations, false afterwards.
    func keepGoing() -> Bool {
        state.withLock { count in
            count += 1
            return count <= allowedCalls
        }
    }
}
