import XCTest
@testable import Cleanora

/// C-04 — TempScanner.
final class TempScannerTests: TempHomeTestCase {
    private let fileManager = FileManager.default
    private let noProgress: @Sendable (ScannerKey, ScannerState) -> Void = { _, _ in }

    /// Scanner with a fixture shared root — tests must never read the real
    /// `/private/tmp`, whose stale entries would leak into assertions.
    private func makeScanner() throws -> TempScanner {
        let sharedRoot = tempHome.deletingLastPathComponent()
            .appendingPathComponent("shared-tmp", isDirectory: true)
        try fileManager.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
        return TempScanner(sharedTempRoot: sharedRoot)
    }

    /// 2 days ago — older than the 24-hour cutoff.
    private func ageEntry(_ url: URL) throws {
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -2 * 86_400)],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Discovery

    func testOldSubdirectoriesAndLooseFilesAreReportedWithRightMethods() async throws {
        let oldDir = try FixtureBuilder.makeTree(
            in: environment.temporaryRoot.appendingPathComponent("stale-session"),
            [("blob.bin", 4_096)]
        )
        try ageEntry(oldDir)
        let oldFile = environment.temporaryRoot.appendingPathComponent("leftover.log")
        try Data(repeating: 0x41, count: 1_024).write(to: oldFile)
        try ageEntry(oldFile)

        let outcome = try await makeScanner().scan(
            in: environment, options: ScanOptions(), onProgress: noProgress
        )

        guard case .produced(let items) = outcome else {
            return XCTFail("expected .produced, got \(outcome)")
        }
        XCTAssertEqual(items.count, 2)
        let dirItem = try XCTUnwrap(items.first { $0.path.lastPathComponent == "stale-session" })
        XCTAssertEqual(dirItem.deletionMethod, .removeContents)
        XCTAssertEqual(dirItem.riskLevel, .safe)
        XCTAssertEqual(dirItem.category, .temporaryFiles)
        XCTAssertEqual(dirItem.fileCount, 1)
        let fileItem = try XCTUnwrap(items.first { $0.path.lastPathComponent == "leftover.log" })
        XCTAssertEqual(fileItem.deletionMethod, .moveToTrash)
        XCTAssertEqual(fileItem.riskLevel, .safe)
    }

    func testEntriesYoungerThan24hAreSkipped() async throws {
        // Fresh entries (no ageing) and one touched 1 hour ago.
        let freshDir = try FixtureBuilder.makeTree(
            in: environment.temporaryRoot.appendingPathComponent("fresh-dir"),
            [("a.bin", 10)]
        )
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: freshDir.path
        )
        let freshFile = environment.temporaryRoot.appendingPathComponent("fresh.log")
        try Data("x".utf8).write(to: freshFile)

        let outcome = try await makeScanner().scan(
            in: environment, options: ScanOptions(), onProgress: noProgress
        )

        XCTAssertEqual(outcome, .produced([]))
    }

    func testSymlinksInTempAreSkipped() async throws {
        let target = try FixtureBuilder.makeTree(
            in: tempHome.appendingPathComponent("link-target"),
            [("data.bin", 50_000)]
        )
        let link = environment.temporaryRoot.appendingPathComponent("risky-link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        try ageEntry(link)

        let outcome = try await makeScanner().scan(
            in: environment, options: ScanOptions(), onProgress: noProgress
        )

        XCTAssertEqual(outcome, .produced([]), "symlinks must never become deletion items")
        XCTAssertTrue(fileManager.fileExists(atPath: target.appendingPathComponent("data.bin").path))
    }

    // MARK: - Ownership

    func testOwnershipPredicate() {
        let uid = getuid()
        XCTAssertTrue(TempScanner.isOwnedByCurrentUser(ownerID: uid))
        XCTAssertFalse(TempScanner.isOwnedByCurrentUser(ownerID: uid &+ 1))
        XCTAssertFalse(TempScanner.isOwnedByCurrentUser(ownerID: nil), "unknown owner is never ours")
    }

    func testOwnerIDReaderUsesFileAttributes() throws {
        let file = environment.temporaryRoot.appendingPathComponent("owned.txt")
        try Data("x".utf8).write(to: file)

        let ownerID = TempScanner.ownerID(of: file)

        XCTAssertEqual(ownerID, getuid())
        XCTAssertEqual(
            TempScanner.ownerID(of: environment.temporaryRoot.appendingPathComponent("missing")),
            nil
        )
    }

    // MARK: - Shared temp root

    func testSharedTempRootIsScannedWithSameRules() async throws {
        let scanner = try makeScanner()
        let oldEntry = try FixtureBuilder.makeTree(
            in: scanner.sharedTempRoot.appendingPathComponent("old-paste"),
            [("f.bin", 2_048)]
        )
        try ageEntry(oldEntry)

        let outcome = try await scanner.scan(
            in: environment, options: ScanOptions(), onProgress: noProgress
        )

        guard case .produced(let items) = outcome else {
            return XCTFail("expected .produced, got \(outcome)")
        }
        XCTAssertEqual(items.map { canonicalTestPath($0.path).path }, [canonicalTestPath(oldEntry).path])
    }

    func testDefaultSharedTempRootIsSystemTemp() {
        XCTAssertEqual(TempScanner().sharedTempRoot.path, "/private/tmp")
    }

    // MARK: - Skip paths

    func testMissingRootsAreSkippedWithPathNotFound() async throws {
        let missingEnv = ScanEnvironment(
            home: tempHome,
            temporaryRoot: tempHome.appendingPathComponent("does-not-exist")
        )
        let scanner = TempScanner(
            sharedTempRoot: tempHome.appendingPathComponent("also-missing")
        )

        let outcome = try await scanner.scan(
            in: missingEnv, options: ScanOptions(), onProgress: noProgress
        )

        guard case .skipped(.pathNotFound(let paths)) = outcome else {
            return XCTFail("expected .skipped(.pathNotFound), got \(outcome)")
        }
        XCTAssertTrue(paths.contains("does-not-exist"))
    }

    func testUnreadableRootsAreSkippedWithPermissionDenied() async throws {
        try XCTSkipUnless(getuid() != 0, "chmod-based unreadability does not apply to root")
        let sharedRoot = tempHome.appendingPathComponent("shared-tmp", isDirectory: true)
        try fileManager.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: environment.temporaryRoot.path
        )
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sharedRoot.path)
        defer {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: environment.temporaryRoot.path
            )
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedRoot.path)
        }

        let outcome = try await TempScanner(sharedTempRoot: sharedRoot).scan(
            in: environment, options: ScanOptions(), onProgress: noProgress
        )

        guard case .skipped(.permissionDenied) = outcome else {
            return XCTFail("expected .skipped(.permissionDenied), got \(outcome)")
        }
    }

    func testReadableRootsWithNothingOldProducesEmptyOutcome() async throws {
        // TempHomeTestCase creates an empty temporaryRoot.
        let outcome = try await makeScanner().scan(
            in: environment, options: ScanOptions(), onProgress: noProgress
        )

        XCTAssertEqual(outcome, .produced([]))
    }

    func testEveryItemReasonIsNonEmpty() async throws {
        let oldDir = try FixtureBuilder.makeTree(
            in: environment.temporaryRoot.appendingPathComponent("old"),
            [("f", 10)]
        )
        try ageEntry(oldDir)

        guard case .produced(let items) = try await makeScanner().scan(
            in: environment, options: ScanOptions(), onProgress: noProgress
        ) else {
            return XCTFail("expected items")
        }
        XCTAssertFalse(items.isEmpty)
        for item in items {
            XCTAssertFalse(item.reason.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
