import XCTest
@testable import Cleanora

/// M-04 — duplicate detection over user-chosen scopes only. Fixtures are
/// real files: identical bytes group, different bytes of equal size do not,
/// symlinks are skipped, blocked subtrees are pruned, and the keeper is the
/// newest file.
final class DuplicateScannerTests: TempHomeTestCase {
    private let scanner = DuplicateScanner()
    private let megabyte = 1_000_000

    /// Test-side progress recorder (sync callback, locked storage).
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [DuplicateProgress] = []

        func add(_ progress: DuplicateProgress) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(progress)
        }

        var all: [DuplicateProgress] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }

        var last: DuplicateProgress? { all.last }
    }

    /// Lets a progress callback cancel the task that owns the scan.
    private final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<[DuplicateGroup], Error>?

        func set(_ task: Task<[DuplicateGroup], Error>) {
            lock.lock()
            defer { lock.unlock() }
            self.task = task
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            task?.cancel()
        }
    }

    // MARK: - Fixtures

    private var scope: URL { tempRoot.appendingPathComponent("scope", isDirectory: true) }

    @discardableResult
    private func write(
        _ relativePath: String,
        fill: UInt8 = 0x41,
        bytes: Int,
        modified: Date? = nil,
        in root: URL
    ) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: fill, count: bytes).write(to: url, options: .atomic)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path
            )
        }
        return url
    }

    private func find(
        in roots: [URL],
        options: DuplicateOptions = DuplicateOptions(),
        onProgress: @escaping @Sendable (DuplicateProgress) -> Void = { _ in }
    ) async throws -> [DuplicateGroup] {
        try await scanner.findDuplicates(
            in: roots, options: options, environment: environment, onProgress: onProgress
        )
    }

    // MARK: - Grouping

    func testIdenticalFilesGroupWithNewestAsKeeper() async throws {
        let older = Date(timeIntervalSinceNow: -86_400)
        try write("project a/one.dat", bytes: 1_200_000, modified: older, in: scope)
        let newer = try write("project b/two.dat", bytes: 1_200_000, modified: Date(), in: scope)

        let groups = try await find(in: [scope])

        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.files.count, 2)
        XCTAssertEqual(
            group.files.first.map(canonicalTestPath),
            canonicalTestPath(newer),
            "newest file is the keeper, listed first"
        )
        XCTAssertEqual(group.totalWastedBytes, 1_200_000, "only the duplicate copy is wasted")
    }

    func testEqualModificationTimesBreakKeeperTieByPath() async throws {
        let same = Date(timeIntervalSinceNow: -60)
        try write("b.dat", bytes: 1_200_000, modified: same, in: scope)
        try write("a.dat", bytes: 1_200_000, modified: same, in: scope)

        let groups = try await find(in: [scope])

        let keeper = try XCTUnwrap(groups.first?.files.first)
        XCTAssertEqual(keeper.lastPathComponent, "a.dat", "tie breaks to the smaller path")
    }

    func testSameSizeDifferentContentIsNotGrouped() async throws {
        try write("one.dat", fill: 0x41, bytes: 1_200_000, in: scope)
        try write("two.dat", fill: 0x42, bytes: 1_200_000, in: scope)

        let groups = try await find(in: [scope])
        XCTAssertTrue(groups.isEmpty)
    }

    func testSameHeadDifferentTailIsNotGrouped() async throws {
        // Identical first 4 KB, divergent beyond it — the head-hash stage
        // cannot decide these, the full hash must.
        let url = try write("head-same.dat", fill: 0x41, bytes: 1_400_000, in: scope)
        try write("tail-diff.dat", fill: 0x41, bytes: 1_400_000, in: scope)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 1_300_000)
        try handle.write(contentsOf: Data([0xFF]))
        try handle.close()

        let groups = try await find(in: [scope])
        XCTAssertTrue(groups.isEmpty)
    }

    func testDifferentSizesWithIdenticalContentAreNotGrouped() async throws {
        try write("small.dat", bytes: 1_200_000, in: scope)
        try write("large.dat", bytes: 1_500_000, in: scope)

        let groups = try await find(in: [scope])
        XCTAssertTrue(groups.isEmpty, "size bucketing runs before any hashing")
    }

    func testMultipleGroupsReportedLargestWasteFirst() async throws {
        // Group A: three 3 MB twins (waste 6 MB). Group B: two 1.2 MB twins.
        for name in ["a1.dat", "a2.dat", "a3.dat"] {
            try write("groupA/\(name)", fill: 0x10, bytes: 3_000_000, in: scope)
        }
        for name in ["b1.dat", "b2.dat"] {
            try write("groupB/\(name)", fill: 0x20, bytes: 1_200_000, in: scope)
        }

        let groups = try await find(in: [scope])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].files.count, 3)
        XCTAssertEqual(groups[0].totalWastedBytes, 6_000_000)
        XCTAssertEqual(groups[1].files.count, 2)
        XCTAssertEqual(groups[1].totalWastedBytes, 1_200_000)
    }

    // MARK: - Gates and pruning

    func testSizeGateExcludesFilesBelowMinimum() async throws {
        try write("tiny-a.dat", bytes: 100, in: scope)
        try write("tiny-b.dat", bytes: 100, in: scope)

        let withDefaults = try await find(in: [scope])
        XCTAssertTrue(withDefaults.isEmpty, "default gate is 1 MB")

        let lowered = try await find(in: [scope], options: DuplicateOptions(minimumFileSize: 1))
        XCTAssertEqual(lowered.count, 1)
        XCTAssertEqual(lowered[0].files.count, 2)
    }

    func testSymlinkedDuplicateIsSkippedNotFollowed() async throws {
        let real = try write("one.dat", bytes: 1_200_000, in: scope)
        try write("two.dat", bytes: 1_200_000, in: scope)
        try FileManager.default.createSymbolicLink(
            at: scope.appendingPathComponent("link.dat"),
            withDestinationURL: real
        )

        let groups = try await find(in: [scope])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.count, 2, "the alias itself is never a candidate")
        XCTAssertFalse(groups[0].files.contains { $0.lastPathComponent == "link.dat" })
    }

    func testBlockedSubtreesInsideScopeArePruned() async throws {
        // Blocked ROOT (home-relative) and blocked FRAGMENT, both inside an
        // otherwise legitimate scope.
        try write("Library/Preferences/com.example/pref-a.dat", bytes: 1_200_000, in: tempHome)
        try write("Library/Preferences/com.example/pref-b.dat", bytes: 1_200_000, in: tempHome)
        try write("Projects/Keychains/cache/key-a.dat", bytes: 1_200_000, in: scope)
        try write("Projects/Keychains/cache/key-b.dat", bytes: 1_200_000, in: scope)
        // A legitimate pair in the same scope must still be found.
        try write("Projects/keep-a.dat", bytes: 1_200_000, in: scope)
        try write("Projects/keep-b.dat", bytes: 1_200_000, in: scope)

        let groups = try await find(in: [tempHome, scope])

        XCTAssertEqual(groups.count, 1, "blocked subtrees contribute nothing")
        XCTAssertEqual(groups[0].files.map(\.lastPathComponent), ["keep-a.dat", "keep-b.dat"])
    }

    // MARK: - Bounds

    func testFileLimitCapsCandidatesDeterministically() async throws {
        let older = Date(timeIntervalSinceNow: -120)
        let newer = Date(timeIntervalSinceNow: -60)
        try write("c.dat", bytes: 1_200_000, modified: older, in: scope)
        try write("a.dat", bytes: 1_200_000, modified: older, in: scope)
        try write("b.dat", bytes: 1_200_000, modified: newer, in: scope)

        let groups = try await find(in: [scope], options: DuplicateOptions(fileLimit: 2))

        XCTAssertEqual(groups.count, 1, "the first two candidates by path still pair up")
        XCTAssertEqual(
            groups[0].files.map(\.lastPathComponent),
            ["b.dat", "a.dat"], // keeper (newest) first, candidates capped in path order
            "candidates are capped in path order"
        )
    }

    func testExpiredTimeBudgetReturnsEmptyResultWithoutThrowing() async throws {
        try write("one.dat", bytes: 1_200_000, in: scope)
        try write("two.dat", bytes: 1_200_000, in: scope)

        let groups = try await find(
            in: [scope], options: DuplicateOptions(timeBudget: 0)
        )
        XCTAssertTrue(groups.isEmpty, "an exhausted budget yields a partial (empty) result")
    }

    // MARK: - Cancellation

    func testCancellationBeforeStartThrows() async throws {
        try write("one.dat", bytes: 1_200_000, in: scope)
        try write("two.dat", bytes: 1_200_000, in: scope)

        // Sendable locals only — the task must not capture the test case.
        let scanner = DuplicateScanner()
        let scopeURL = scope
        let task = Task<[DuplicateGroup], Error> {
            try await scanner.findDuplicates(in: [scopeURL], options: DuplicateOptions())
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMidScanCancellationThrowsAndAbortsHashing() async throws {
        for index in 0..<400 {
            try write("bulk/\(index).dat", bytes: 16, in: scope)
        }

        let recorder = ProgressRecorder()
        let box = CancelBox()
        // Sendable locals only — the task must not capture the test case.
        let scanner = DuplicateScanner()
        let scopeURL = scope
        let scanEnvironment: ScanEnvironment = environment
        let task = Task<[DuplicateGroup], Error> {
            try await scanner.findDuplicates(
                in: [scopeURL],
                options: DuplicateOptions(minimumFileSize: 1),
                environment: scanEnvironment,
                onProgress: { progress in
                    recorder.add(progress)
                    if progress.filesExamined >= 20 { box.cancel() }
                }
            )
        }
        box.set(task)

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            XCTAssertLessThan(
                recorder.last?.filesExamined ?? 0,
                400,
                "cancellation took effect mid-walk, not after the whole scan"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Progress

    func testProgressCountsExaminedFilesAndFoundGroups() async throws {
        try write("one.dat", bytes: 1_200_000, in: scope)
        try write("two.dat", bytes: 1_200_000, in: scope)

        let recorder = ProgressRecorder()
        _ = try await find(in: [scope], onProgress: { recorder.add($0) })

        XCTAssertEqual(
            recorder.last,
            DuplicateProgress(filesExamined: 2, bytesExamined: 2_400_000, duplicateGroupsFound: 1)
        )
    }
}
