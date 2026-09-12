import XCTest
@testable import Cleanora

/// C-05 — LogScanner.
final class LogScannerTests: TempHomeTestCase {
    private let scanner = LogScanner()
    private let fileManager = FileManager.default
    private let noProgress: @Sendable (ScannerKey, ScannerState) -> Void = { _, _ in }

    /// 30 days ago — older than the 7-day cutoff.
    private func ageEntry(_ url: URL) throws {
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -30 * 86_400)],
            ofItemAtPath: url.path
        )
    }

    @discardableResult
    private func makeOldEntry(at url: URL, size: Int = 1_024) throws -> URL {
        try FixtureBuilder.makeTree(in: url, [("data.bin", size)])
        try ageEntry(url)
        return url
    }

    private func scan() async throws -> ScannerOutcome {
        try await scanner.scan(in: environment, options: ScanOptions(), onProgress: noProgress)
    }

    private func producedItems(_ outcome: ScannerOutcome) throws -> [CleanupItem] {
        guard case .produced(let items) = outcome else {
            XCTFail("expected .produced, got \(outcome)")
            return []
        }
        return items
    }

    // MARK: - Discovery

    func testOldLogDirectoriesAreReportedAsTrashDirectory() async throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        let old = try makeOldEntry(at: environment.logs.appendingPathComponent("AppWithOldLogs"))

        let items = try producedItems(try await scan())

        XCTAssertEqual(items.map { canonicalTestPath($0.path).path }, [canonicalTestPath(old).path])
        XCTAssertEqual(items.first?.deletionMethod, .trashDirectory)
        XCTAssertEqual(items.first?.riskLevel, .safe)
        XCTAssertEqual(items.first?.category, .logs)
        XCTAssertGreaterThan(items.first?.size ?? 0, 0)
    }

    func testRecentLogEntriesAreExcluded() async throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        // Six days old — inside the 7-day window, so still "live".
        let recent = try FixtureBuilder.makeTree(
            in: environment.logs.appendingPathComponent("ActiveApp"),
            [("data.bin", 1_024)]
        )
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -6 * 86_400)],
            ofItemAtPath: recent.path
        )
        // Eight days old — outside the window.
        let old = try FixtureBuilder.makeTree(
            in: environment.logs.appendingPathComponent("StaleApp"),
            [("data.bin", 1_024)]
        )
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -8 * 86_400)],
            ofItemAtPath: old.path
        )

        let items = try producedItems(try await scan())

        XCTAssertEqual(items.map { canonicalTestPath($0.path).path }, [canonicalTestPath(old).path])
    }

    func testOldLooseLogFilesAreReportedWithMoveToTrash() async throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        let file = environment.logs.appendingPathComponent("app-2026-01-01.log")
        try Data(repeating: 0x41, count: 2_048).write(to: file)
        try ageEntry(file)

        let items = try producedItems(try await scan())

        XCTAssertEqual(items.map { canonicalTestPath($0.path).path }, [canonicalTestPath(file).path])
        XCTAssertEqual(items.first?.deletionMethod, .moveToTrash)
    }

    // MARK: - The three roots

    func testDiagnosticReportsRootIsScannedWithoutDoubleCounting() async throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        let report = try makeOldEntry(
            at: environment.diagnosticReports.appendingPathComponent("Cleanora-2026-01-01.ips")
        )

        let items = try producedItems(try await scan())

        XCTAssertEqual(items.map { canonicalTestPath($0.path).path }, [canonicalTestPath(report).path])
        // The DiagnosticReports directory itself must never appear — its own
        // root covers it, otherwise the coordinator would see both.
        XCTAssertFalse(items.contains { $0.path.lastPathComponent == "DiagnosticReports" })
    }

    func testCrashReporterRootIsScanned() async throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        let crash = try makeOldEntry(
            at: environment.applicationSupport
                .appendingPathComponent("CrashReporter")
                .appendingPathComponent("SomeApp")
        )

        let items = try producedItems(try await scan())

        XCTAssertEqual(items.map { canonicalTestPath($0.path).path }, [canonicalTestPath(crash).path])
        XCTAssertEqual(items.first?.deletionMethod, .trashDirectory)
    }

    func testReasonsAreNonEmptyEverywhere() async throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        try makeOldEntry(at: environment.logs.appendingPathComponent("OldApp"))
        try makeOldEntry(
            at: environment.diagnosticReports.appendingPathComponent("crash.ips")
        )
        try makeOldEntry(
            at: environment.applicationSupport
                .appendingPathComponent("CrashReporter")
                .appendingPathComponent("App")
        )

        let items = try producedItems(try await scan())

        XCTAssertEqual(items.count, 3)
        for item in items {
            XCTAssertFalse(item.reason.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Skip paths

    func testNoLogRootsAtAllIsSkippedWithPathNotFound() async throws {
        // No Library/ skeleton: none of the three roots exist.
        let outcome = try await scan()

        guard case .skipped(.pathNotFound(let paths)) = outcome else {
            return XCTFail("expected .skipped(.pathNotFound), got \(outcome)")
        }
        XCTAssertTrue(paths.contains(environment.logs.path))
        XCTAssertTrue(paths.contains(environment.diagnosticReports.path))
    }

    func testPartiallyMissingRootsStillScanTheRest() async throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        let old = try makeOldEntry(at: environment.logs.appendingPathComponent("OldApp"))

        let items = try producedItems(try await scan())

        XCTAssertEqual(items.map { canonicalTestPath($0.path).path }, [canonicalTestPath(old).path])
    }

    func testNothingOldProducesEmptyOutcome() async throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)

        let outcome = try await scan()

        XCTAssertEqual(outcome, .produced([]))
    }
}
