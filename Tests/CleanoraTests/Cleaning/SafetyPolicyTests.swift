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
        risk: RiskLevel = .safe,
        selected: Bool = true,
        confirmation: CleanupItem.ConfirmationLevel = .standard,
        deletionMethod: DeletionMethod = .trashDirectory
    ) -> CleanupItem {
        CleanupItem(
            name: "Test Item",
            category: .applicationCaches,
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

    // I10
    func testOwnLogsExcluded() {
        let logURL = AppDirectories(home: tempHome).logsDirectory
            .appendingPathComponent("cleanup-2026-09-12.jsonl")
        try? FileManager.default.createDirectory(
            at: AppDirectories(home: tempHome).logsDirectory,
            withIntermediateDirectories: true
        )
        try? Data("{}".utf8).write(to: logURL)
        let item = makeItem(path: logURL)
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id]))
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
}
