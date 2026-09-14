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

    // Scanner-produced roots (engine-a C-04/C-05) must validate.
    func testCrashReporterRootAllowed() throws {
        let item = makeItem(
            path: tempHome.appendingPathComponent("Library/Application Support/CrashReporter/2026-09-01.ops")
        )
        XCTAssertNoThrow(try policy.validate(item, confirmed: [item.id]))
    }

    func testPrivateTmpRootAllowed() throws {
        let item = makeItem(path: URL(fileURLWithPath: "/private/tmp/cleanora-user-file.tmp"))
        XCTAssertNoThrow(try policy.validate(item, confirmed: [item.id]))
    }

    // Large-files carve-out: recoverable trash + review risk + user-selected,
    // anywhere under home (spec §7 "Review — the user decides").
    func testLargeFileUnderArbitraryHomePathAllowedWithCarveOut() throws {
        let bigFile = tempHome.appendingPathComponent("Projects/big.bin")
        try FixtureBuilder.makeTree(in: bigFile.deletingLastPathComponent(), [("big.bin", 10)])
        let item = makeItem(
            path: bigFile, category: .largeFiles,
            risk: .review, deletionMethod: .moveToTrash
        )
        XCTAssertNoThrow(try policy.validate(item, confirmed: [item.id]))
    }

    func testLargeFileCarveOutStillRespectsBlockedPaths() {
        let item = makeItem(
            path: tempHome.appendingPathComponent("Documents/big.bin"),
            category: .largeFiles, risk: .review, deletionMethod: .moveToTrash
        )
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id]))
    }

    func testLargeFileCarveOutRequiresMoveToTrash() {
        // Permanent removal stays forbidden outside the allowlist even for
        // large files.
        let item = makeItem(
            path: tempHome.appendingPathComponent("Projects/big.bin"),
            category: .largeFiles, risk: .review, deletionMethod: .removeContents
        )
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id]))
    }

    func testNonLargeFileOutsideAllowlistStillRejected() {
        let item = makeItem(path: tempHome.appendingPathComponent("Projects/thing"))
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id]))
    }

    // Carve-out pins (reviewer finding 6): a future "simplification" must
    // not silently widen the large-files carve-out.
    func testLargeFileCarveOutRequiresReviewRisk() {
        let item = makeItem(
            path: tempHome.appendingPathComponent("Projects/big.bin"),
            category: .largeFiles, risk: .safe,
            deletionMethod: .moveToTrash
        )
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id]))
    }

    func testLargeFileCarveOutStillRequiresDestructiveConfirmWhenMarkedDestructive() {
        let item = makeItem(
            path: tempHome.appendingPathComponent("Projects/big.bin"),
            category: .largeFiles, risk: .review,
            confirmation: .destructive, deletionMethod: .moveToTrash
        )
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id])) { error in
            guard case SafetyPolicy.Violation.destructiveWithoutExplicitConfirm = error else {
                return XCTFail("expected destructiveWithoutExplicitConfirm, got \(error)")
            }
        }
    }

    // Uninstaller carve-out (Phase 3): .appLeftovers + .moveToTrash + .review
    // admits the app bundle under /Applications and leftover files under
    // home — blocked roots still win.
    func testAppLeftoversBundleUnderApplicationsAllowed() throws {
        let bundle = ScanEnvironment.systemApplications
            .appendingPathComponent("SomeApp.app", isDirectory: true)
        let item = makeItem(
            path: bundle, category: .appLeftovers,
            risk: .review, deletionMethod: .moveToTrash
        )
        XCTAssertNoThrow(try policy.validate(item, confirmed: [item.id]))
    }

    func testAppLeftoversUnderHomeAllowed() throws {
        let item = makeItem(
            path: tempHome.appendingPathComponent("Library/Application Support/SomeApp"),
            category: .appLeftovers, risk: .review, deletionMethod: .moveToTrash
        )
        XCTAssertNoThrow(try policy.validate(item, confirmed: [item.id]))
    }

    func testAppLeftoversPreferencesPlistStillBlocked() {
        let item = makeItem(
            path: tempHome.appendingPathComponent("Library/Preferences/com.someapp.plist"),
            category: .appLeftovers, risk: .review, deletionMethod: .moveToTrash
        )
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id])) { error in
            XCTAssertEqual(
                error as? SafetyPolicy.Violation,
                .blockedPath(policy.canonicalized(
                    tempHome.appendingPathComponent("Library/Preferences/com.someapp.plist")
                ).path)
            )
        }
    }

    func testAppLeftoversContainersStillBlocked() {
        let item = makeItem(
            path: tempHome.appendingPathComponent("Library/Containers/com.someapp"),
            category: .appLeftovers, risk: .review, deletionMethod: .moveToTrash
        )
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id]))
    }

    func testAppLeftoversCarveOutRequiresReviewRisk() {
        let item = makeItem(
            path: tempHome.appendingPathComponent("Library/Application Support/SomeApp"),
            category: .appLeftovers, risk: .safe, deletionMethod: .moveToTrash
        )
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id]))
    }

    func testAppLeftoversCarveOutOutsideHomeAndApplicationsRejected() {
        let item = makeItem(
            path: URL(fileURLWithPath: "/Volumes/External/Apps/SomeApp.app"),
            category: .appLeftovers, risk: .review, deletionMethod: .moveToTrash
        )
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id]))
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

    // An allowed-root path whose symlink resolves OUT of the allowlist
    // must be judged by its target (canonicalization runs before checks).
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

    // Symlink-leaf gate (Phase 2 backlog fix): a link that canonicalization
    // cannot resolve — the classic case being a DANGLING symlink inside an
    // allowed root, which canonicalizes to the link path itself — must not
    // be hard-deleted. Permanent removal of an unverifiable link is refused.
    func testDanglingSymlinkLeafRemoveContentsRejected() throws {
        let fm = FileManager.default
        let caches = tempHome.appendingPathComponent("Library/Caches")
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let dangling = caches.appendingPathComponent("dangling")
        try fm.createSymbolicLink(
            at: dangling,
            withDestinationURL: tempHome.appendingPathComponent("Documents/never-existed")
        )

        let item = makeItem(path: dangling, deletionMethod: .removeContents)
        let expected = policy.canonicalized(item.path).path
        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id])) { error in
            XCTAssertEqual(error as? SafetyPolicy.Violation, .symlinkLeafNotAllowed(expected))
        }
    }

    // Trashing a symlink leaf is always safe and recoverable (I7: the target
    // is never touched), so `.trashDirectory` stays allowed even for a
    // dangling leaf.
    func testDanglingSymlinkLeafTrashDirectoryAllowed() throws {
        let fm = FileManager.default
        let caches = tempHome.appendingPathComponent("Library/Caches")
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let dangling = caches.appendingPathComponent("dangling")
        try fm.createSymbolicLink(
            at: dangling,
            withDestinationURL: tempHome.appendingPathComponent("Documents/never-existed")
        )

        let item = makeItem(path: dangling, deletionMethod: .trashDirectory)
        XCTAssertNoThrow(try policy.validate(item, confirmed: [item.id]))
    }

    // A live link whose target is inside an allowed root keeps validating —
    // it resolves to the target, which is not itself a symlink leaf.
    func testLiveSymlinkResolvingInsideAllowedRootTrashDirectoryAllowed() throws {
        let fm = FileManager.default
        let caches = tempHome.appendingPathComponent("Library/Caches")
        let real = caches.appendingPathComponent("real-dir")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let link = caches.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let item = makeItem(path: link, deletionMethod: .trashDirectory)
        XCTAssertEqual(policy.canonicalized(item.path).path, policy.canonicalized(real).path)
        XCTAssertNoThrow(try policy.validate(item, confirmed: [item.id]))
    }

    // An escaping live link stays rejected regardless of deletion method —
    // existing behavior, judged by its (outside) target before the leaf gate.
    func testLiveSymlinkEscapingAllowlistRemoveContentsRejected() throws {
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
        let item = makeItem(path: escape, deletionMethod: .removeContents)
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
