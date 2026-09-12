import XCTest
@testable import Cleanora

final class SafetyPolicyTests: TempHomeTestCase {
    private var policy: SafetyPolicy!

    override func setUpWithError() throws {
        try super.setUpWithError()
        policy = SafetyPolicy.standard(home: tempHome, tempRoot: tempRoot)
    }

    private func makeItem(
        path: URL,
        category: ScanCategory = .applicationCaches,
        risk: RiskLevel = .safe,
        selected: Bool = true,
        confirmation: CleanupItem.ConfirmationLevel = .standard,
        deletionMethod: DeletionMethod = .trashDirectory
    ) -> CleanupItem {
        CleanupItem(
            name: "Test Item",
            category: category,
            path: path,
            size: 10,
            riskLevel: risk,
            selected: selected,
            reason: "test",
            deletionMethod: deletionMethod,
            confirmationLevel: confirmation
        )
    }

    // I2
    func testRejectsPathOutsideAllowlist() {
        let item = makeItem(path: tempHome.appendingPathComponent("Documents/secret.txt"))
        let expected = policy.canonicalized(item.path).path
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id])) { error in
            XCTAssertEqual(error as? SafetyPolicy.Violation, .outsideAllowedRoots(expected))
        }
    }

    func testAcceptsPathInsideAllowedRoot() throws {
        let item = makeItem(path: tempHome.appendingPathComponent("Library/Caches/com.example.app"))
        XCTAssertNoThrow(try policy.validate(item, confirmed: [item.id]))
    }

    // I3
    func testBlockedFragmentWinsEvenInsideAllowedRoot() {
        let item = makeItem(path: tempHome.appendingPathComponent("Library/Caches/Mobile Documents/thing"))
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id])) { error in
            XCTAssertEqual(error as? SafetyPolicy.Violation, .blockedFragment("Mobile Documents"))
        }
    }

    func testKeychainsBlocked() {
        let item = makeItem(path: tempHome.appendingPathComponent("Library/Keychains/keys"))
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id]))
    }

    // I4
    func testUnselectedRejected() {
        let item = makeItem(path: tempHome.appendingPathComponent("Library/Logs/app"), selected: false)
        let expected = policy.canonicalized(item.path).path
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id])) { error in
            XCTAssertEqual(error as? SafetyPolicy.Violation, .itemNotSelected(expected))
        }
    }

    // I5
    func testMissingConfirmationRejected() {
        let item = makeItem(path: tempHome.appendingPathComponent("Library/Logs/app"))
        let expected = policy.canonicalized(item.path).path
        XCTAssertThrowsError(try policy.validate(item, confirmed: [])) { error in
            XCTAssertEqual(error as? SafetyPolicy.Violation, .missingConfirmation(expected))
        }
    }

    // I6
    func testDestructiveRequiresExplicitConfirm() {
        let item = makeItem(
            path: tempHome.appendingPathComponent(".Trash"),
            confirmation: .destructive,
            deletionMethod: .removeContents
        )
        let expected = policy.canonicalized(item.path).path
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id])) { error in
            XCTAssertEqual(error as? SafetyPolicy.Violation, .destructiveWithoutExplicitConfirm(expected))
        }
    }

    // I6 positive case: destructive + explicit flag passes the gate.
    func testDestructivePassesWithExplicitConfirm() throws {
        let item = makeItem(
            path: tempHome.appendingPathComponent(".Trash"),
            confirmation: .destructive,
            deletionMethod: .removeContents
        )
        XCTAssertNoThrow(
            try policy.validate(item, confirmed: [item.id], destructiveConfirmed: true)
        )
    }

    // The gate never trusts the producer: a Trash-category item carrying the
    // default `.standard` confirmation is rejected even with batch consent.
    func testTrashCategoryWithoutDestructiveMarkingRejected() {
        let item = makeItem(
            path: tempHome.appendingPathComponent(".Trash/some-file"),
            category: .trash
        )
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id])) { error in
            guard case SafetyPolicy.Violation.destructiveWithoutExplicitConfirm = error else {
                return XCTFail("expected destructiveWithoutExplicitConfirm, got \(error)")
            }
        }
    }

    // Permanent removal is legal only for `.safe` data.
    func testRemoveContentsOnReviewRiskRejected() {
        let item = makeItem(
            path: tempHome.appendingPathComponent("Library/Developer/Xcode/Archives/old.xcarchive"),
            risk: .review,
            deletionMethod: .removeContents
        )
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id]))
    }

    func testRemoveContentsOnSafeRiskAccepted() throws {
        let item = makeItem(
            path: tempHome.appendingPathComponent("Library/Caches/com.example.app"),
            risk: .safe,
            deletionMethod: .removeContents
        )
        XCTAssertNoThrow(try policy.validate(item, confirmed: [item.id]))
    }

    // Relative paths resolve against a mutable CWD — always rejected.
    func testRelativePathRejected() {
        let item = makeItem(path: URL(fileURLWithPath: "relative/dir"))
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id])) { error in
            XCTAssertEqual(
                error as? SafetyPolicy.Violation,
                .outsideAllowedRoots("relative/dir")
            )
        }
    }

    // I10 — assert the specific violation, not just "throws".
    func testOwnLogsExcluded() throws {
        let logURL = AppDirectories(home: tempHome).logsDirectory
            .appendingPathComponent("cleanup-2026-09-12.jsonl")
        try FileManager.default.createDirectory(
            at: AppDirectories(home: tempHome).logsDirectory,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: logURL)
        let item = makeItem(path: logURL)
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id])) { error in
            XCTAssertEqual(error as? SafetyPolicy.Violation, .blockedPath(policy.canonicalized(logURL).path))
        }
    }

    // Canonicalization: /tmp vs /private/tmp must resolve to the same path.
    func testCanonicalizationResolvesSymlink() throws {
        let fm = FileManager.default
        let real = tempHome.appendingPathComponent("Library/Logs/real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let link = tempRoot.appendingPathComponent("alias")
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        // A policy built with the symlinked temp root must accept the resolved path.
        let item = makeItem(path: link)
        XCTAssertNoThrow(try policy.validate(item, confirmed: [item.id]))
    }

    func testCanonicalizedCollapsesTmpToPrivateTmp() {
        let url = policy.canonicalized(URL(fileURLWithPath: "/tmp"))
        XCTAssertFalse(url.path.hasPrefix("/tmp/"))
        XCTAssertTrue(url.path == "/private/tmp" || url.path.hasPrefix("/private/tmp"))
    }

    // Gap: an allowed-root path whose symlink resolves OUT of the allowlist
    // must be judged by its target (canonicalization runs before checks).
    // NOTE: this holds only when the target EXISTS — a dangling symlink
    // canonicalizes to the link path itself and passes the gate (reported
    // to the lead as a SafetyPolicy gap; not fixable here, policy is frozen).
    func testSymlinkEscapingAllowlistRejected() throws {
        let fm = FileManager.default
        let documents = tempHome.appendingPathComponent("Documents")
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: documents.appendingPathComponent("secret.txt"))
        try fm.createDirectory(
            at: tempHome.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true
        )
        let escape = tempHome.appendingPathComponent("Library/Caches/escape")
        try fm.createSymbolicLink(
            at: escape,
            withDestinationURL: documents.appendingPathComponent("secret.txt")
        )
        let item = makeItem(path: escape)
        let expected = policy.canonicalized(escape).path
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id])) { error in
            XCTAssertEqual(error as? SafetyPolicy.Violation, .outsideAllowedRoots(expected))
        }
    }

    // Gap: `..` must not survive canonicalization — a traversal into
    // Preferences lands outside the allowlist and is rejected.
    func testDotDotTraversalIntoBlockedRootRejected() {
        let item = makeItem(path: tempHome.appendingPathComponent("Library/Caches/../Preferences/notes.txt"))
        let expected = policy.canonicalized(item.path).path
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id])) { error in
            XCTAssertEqual(error as? SafetyPolicy.Violation, .outsideAllowedRoots(expected))
        }
    }
}
