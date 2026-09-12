import XCTest
@testable import Cleanora

/// C-07 — LargeFileScanner: regular files at or above the threshold, capped
/// and sorted descending, blocked paths excluded, always review + moveToTrash.
final class LargeFileScannerTests: TempHomeTestCase {
    private let scanner = LargeFileScanner()
    private let noProgress: @Sendable (ScannerKey, ScannerState) -> Void = { _, _ in }

    /// 10_000 sits between APFS block granularity (4 KiB) and the fixture
    /// file sizes, so allocated-size comparisons stay unambiguous.
    private func options(
        minimum: Int64 = 10_000,
        limit: Int = 100,
        budget: TimeInterval = 120
    ) -> ScanOptions {
        ScanOptions(
            enabledCategories: Set(ScanCategory.phaseOne + [.largeFiles]),
            largeFileMinimumBytes: minimum,
            largeFileLimit: limit,
            perScanTimeBudget: budget
        )
    }

    private func scan(
        _ options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void = { _, _ in }
    ) async throws -> ScannerOutcome {
        try await scanner.scan(in: environment, options: options, onProgress: onProgress)
    }

    private func producedItems(_ outcome: ScannerOutcome, file: StaticString = #filePath, line: UInt = #line)
        -> [CleanupItem] {
        guard case .produced(let items) = outcome else {
            XCTFail("expected .produced, got \(outcome)", file: file, line: line)
            return []
        }
        return items
    }

    /// Block-aligned file sizes keep the allocated-size ordering exact.
    private func makeFile(_ relativePath: String, bytes: Int) throws -> URL {
        try FixtureBuilder.makeTree(in: environment.home, [(relativePath, bytes)])
        return environment.home.appendingPathComponent(relativePath)
    }

    // MARK: - Discovery

    func testFindsLargeFilesSortedDescending() async throws {
        let medium = try makeFile("Projects/render/out.mov", bytes: 20_480)
        let large = try makeFile("big-export.psd", bytes: 32_768)
        _ = try makeFile("notes.txt", bytes: 256)      // allocated 4 KiB: below threshold
        _ = try makeFile("Projects/tiny.bin", bytes: 512)

        let items = producedItems(try await scan(options()))

        XCTAssertEqual(
            items.map { canonicalTestPath($0.path).path },
            [large, medium].map { canonicalTestPath($0).path },
            "descending by size; sub-threshold files stay out"
        )
    }

    func testEveryItemIsReviewMoveToTrashWithoutAppGrouping() async throws {
        _ = try makeFile("Projects/vm-image.img", bytes: 16_384)

        let items = producedItems(try await scan(options()))

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.category, .largeFiles)
        XCTAssertEqual(item.riskLevel, .review)
        XCTAssertEqual(item.deletionMethod, .moveToTrash)
        XCTAssertEqual(item.confirmationLevel, .standard)
        XCTAssertNil(item.appName, "large files are never grouped under an app")
        XCTAssertEqual(item.selected, false, "review rows never preselect")
        XCTAssertEqual(item.fileCount, 1)
        XCTAssertGreaterThan(item.size, 0)
        XCTAssertFalse(item.reason.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func testLimitKeepsOnlyTheLargestFiles() async throws {
        _ = try makeFile("a.bin", bytes: 32_768)
        _ = try makeFile("b.bin", bytes: 20_480)
        _ = try makeFile("c.bin", bytes: 12_288)

        let items = producedItems(try await scan(options(limit: 2)))

        XCTAssertEqual(items.map(\.name), ["a.bin", "b.bin"])
    }

    func testThresholdAboveEveryFileSizeProducesNothing() async throws {
        _ = try makeFile("medium.bin", bytes: 20_480)

        let outcome = try await scan(options(minimum: 1_000_000_000))
        XCTAssertEqual(producedItems(outcome), [])
    }

    // MARK: - Exclusions (blocked roots, fragments, Trash)

    func testBlockedRootsAndFragmentsAreExcluded() async throws {
        let allowed = try makeFile("Projects/kept.bin", bytes: 32_768)
        // Blocked roots (mirror of SafetyPolicy.blockedPaths):
        _ = try makeFile("Documents/ignored.mov", bytes: 32_768)
        _ = try makeFile("Downloads/ignored.dmg", bytes: 32_768)
        _ = try makeFile("Desktop/ignored.iso", bytes: 32_768)
        _ = try makeFile("Library/Keychains/ignored.bin", bytes: 32_768)
        // Blocked fragment with no matching root:
        _ = try makeFile("Library/Caches/iCloud Drive/ignored.bin", bytes: 32_768)
        // I10: Cleanora's own Application Support subtree:
        _ = try makeFile("Library/Application Support/Cleanora/ignored.bin", bytes: 32_768)
        // TrashScanner owns Trash content:
        _ = try makeFile(".Trash/ignored.bin", bytes: 32_768)

        let items = producedItems(try await scan(options()))

        XCTAssertEqual(items.map { canonicalTestPath($0.path).path }, [canonicalTestPath(allowed).path])
    }

    func testSymlinksAreNeverFollowedOrCounted() async throws {
        // The target lives OUTSIDE the scanned home so the only way it could
        // surface is by following the link — which I7 forbids.
        let outside = tempRoot.appendingPathComponent("real-target.bin")
        try Data(repeating: 0x41, count: 32_768).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: environment.home.appendingPathComponent("link.bin"),
            withDestinationURL: outside
        )

        let items = producedItems(try await scan(options()))

        XCTAssertTrue(items.isEmpty, "symlinks are neither followed nor reported (I7)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "target untouched")
    }

    func testDepthBeyondFourIsNotScanned() async throws {
        _ = try makeFile("a/b/c/deep.bin", bytes: 32_768)        // depth 4: in scope
        _ = try makeFile("a/b/c/d/too-deep.bin", bytes: 32_768)  // depth 5: out of scope

        let items = producedItems(try await scan(options()))

        XCTAssertEqual(items.map(\.name), ["deep.bin"])
    }

    // MARK: - Budget

    func testExhaustedBudgetWithoutFindingsYieldsTooLargeToScan() async throws {
        // A zero budget stops the walk before any directory yields candidates
        // (deterministic: the deadline check runs after each directory).
        _ = try makeFile("Projects/nested/below-the-walk.bin", bytes: 32_768)

        let recorder = StateRecorder()
        let outcome = try await scan(options(budget: 0)) { key, state in
            recorder.record(key, state)
        }

        XCTAssertEqual(outcome, .skipped(.tooLargeToScan))
        guard case .skipped(.tooLargeToScan)? = recorder.states[ScannerKey(id: .largeFiles)] else {
            return XCTFail("expected a .tooLargeToScan progress note, got \(recorder.states)")
        }
    }

    func testFindingsBeforeBudgetExhaustionSurvive() async throws {
        // The home directory itself is processed before the zero budget trips,
        // so its depth-1 file is a deterministic partial finding.
        let kept = try makeFile("top-level.bin", bytes: 32_768)
        _ = try makeFile("Projects/nested/never-reached.bin", bytes: 32_768)

        let recorder = StateRecorder()
        let items = producedItems(try await scan(options(budget: 0)) { key, state in
            recorder.record(key, state)
        })

        guard case .skipped(.tooLargeToScan)? = recorder.states[ScannerKey(id: .largeFiles)] else {
            return XCTFail("partial output still carries the .tooLargeToScan note, got \(recorder.states)")
        }
        XCTAssertEqual(items.map { canonicalTestPath($0.path).path }, [canonicalTestPath(kept).path])
    }

    // MARK: - Gating

    func testDisabledCategoryIsSkippedForTheUser() async throws {
        let outcome = try await scanner.scan(
            in: environment,
            options: ScanOptions(), // phase-one categories only
            onProgress: noProgress
        )
        XCTAssertEqual(outcome, .skipped(.disabledByUser))
    }
}
