import XCTest
@testable import Cleanora

/// C-06 — TrashScanner.
final class TrashScannerTests: TempHomeTestCase {
    private let scanner = TrashScanner()
    private let fileManager = FileManager.default
    private let noProgress: @Sendable (ScannerKey, ScannerState) -> Void = { _, _ in }

    private func scan() async throws -> ScannerOutcome {
        try await scanner.scan(in: environment, options: ScanOptions(), onProgress: noProgress)
    }

    func testTrashIsOneDestructiveRemoveContentsItem() async throws {
        try FixtureBuilder.makeTree(in: environment.trash, [
            ("deleted-file.bin", 4_096),
            ("subfolder/inner.bin", 2_048),
        ])

        let outcome = try await scan()

        guard case .produced(let items) = outcome else {
            return XCTFail("expected .produced, got \(outcome)")
        }
        XCTAssertEqual(items.count, 1, "the whole Trash is a single item, not one per entry")
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.path.path, environment.trash.path)
        XCTAssertEqual(item.category, .trash)
        XCTAssertEqual(item.riskLevel, .safe)
        XCTAssertEqual(item.deletionMethod, .removeContents)
        XCTAssertEqual(item.confirmationLevel, .destructive)
        XCTAssertEqual(item.fileCount, 2)
        XCTAssertGreaterThan(item.size, 0)
        XCTAssertFalse(item.reason.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func testReasonStatesIrreversibility() async throws {
        try FixtureBuilder.makeTree(in: environment.trash, [("f.bin", 10)])

        guard case .produced(let items) = try await scan(), let item = items.first else {
            return XCTFail("expected an item")
        }

        let reason = item.reason.lowercased()
        XCTAssertTrue(
            reason.contains("irreversib") || reason.contains("cannot be undone"),
            "reason must state irreversibility, got: \(item.reason)"
        )
    }

    func testEmptyTrashProducesNoItems() async throws {
        try FixtureBuilder.makeTree(in: environment.trash, [])

        let outcome = try await scan()

        XCTAssertEqual(outcome, .produced([]))
    }

    func testMissingTrashIsSkippedWithPathNotFound() async throws {
        let outcome = try await scan()

        XCTAssertEqual(outcome, .skipped(.pathNotFound(environment.trash.path)))
    }

    func testUnreadableTrashIsSkippedWithPermissionDenied() async throws {
        try XCTSkipUnless(getuid() != 0, "chmod-based unreadability does not apply to root")
        try FixtureBuilder.makeTree(in: environment.trash, [("f.bin", 10)])
        try fileManager.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: environment.trash.path
        )
        defer {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: environment.trash.path
            )
        }

        let outcome = try await scan()

        XCTAssertEqual(outcome, .skipped(.permissionDenied(environment.trash.path)))
    }
}
