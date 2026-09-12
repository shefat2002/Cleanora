import XCTest
@testable import Cleanora

/// The Scanning-side mirror of SafetyPolicy's forbidden set. Scanning cannot
/// import Cleaning (layering), so the duplication is deliberate — these tests
/// pin the two lists to each other so they cannot drift apart silently.
final class BlockedPathsTests: TempHomeTestCase {
    // MARK: - Mirror checks against SafetyPolicy

    func testEveryBlockedRootIsRejectedByTheSafetyGate() throws {
        let policy = SafetyPolicy.standard(home: tempHome, tempRoot: tempRoot)
        for root in BlockedPaths.blockedRoots(home: tempHome) {
            let item = CleanupItem(
                name: "probe",
                category: .largeFiles,
                path: root.appendingPathComponent("probe.bin"),
                size: 1_024,
                riskLevel: .review,
                selected: true,
                reason: "mirror probe",
                deletionMethod: .moveToTrash
            )
            XCTAssertThrowsError(
                try policy.validate(item, confirmed: [item.id]),
                "blocked root no longer rejected: \(root.path)"
            ) { error in
                guard case SafetyPolicy.Violation.blockedPath = error else {
                    return XCTFail("expected .blockedPath for \(root.path), got \(error)")
                }
            }
        }
    }

    func testEveryBlockedFragmentIsRejectedByTheSafetyGate() throws {
        let policy = SafetyPolicy.standard(home: tempHome, tempRoot: tempRoot)
        // Fragment probes live under an ALLOWED root so only the fragment
        // rule can reject them.
        for fragment in BlockedPaths.blockedFragments {
            let item = CleanupItem(
                name: "probe",
                category: .largeFiles,
                path: environment.caches
                    .appendingPathComponent(fragment, isDirectory: true)
                    .appendingPathComponent("probe.bin"),
                size: 1_024,
                riskLevel: .review,
                selected: true,
                reason: "mirror probe",
                deletionMethod: .moveToTrash
            )
            XCTAssertThrowsError(
                try policy.validate(item, confirmed: [item.id]),
                "fragment no longer rejected: \(fragment)"
            ) { error in
                guard case SafetyPolicy.Violation.blockedFragment = error else {
                    return XCTFail("expected .blockedFragment for \(fragment), got \(error)")
                }
            }
        }
    }

    // MARK: - Predicate behavior

    func testIsBlockedMatchesRootsAndFragments() {
        let home: URL = tempHome
        XCTAssertTrue(
            BlockedPaths.isBlocked(home.appendingPathComponent("Documents/notes/x.bin").path, home: home)
        )
        XCTAssertTrue(
            BlockedPaths.isBlocked(
                home.appendingPathComponent("Library/Application Support/Cleanora/Logs/a.jsonl").path,
                home: home
            ),
            "I10: Cleanora's own Application Support subtree is blocked too"
        )
        XCTAssertTrue(
            BlockedPaths.isBlocked(
                home.appendingPathComponent("Library/Caches/iCloud Drive/x.bin").path,
                home: home
            ),
            "fragments match anywhere in the path"
        )
        XCTAssertFalse(
            BlockedPaths.isBlocked(home.appendingPathComponent("Projects/build/out.bin").path, home: home)
        )
        // The mirror is for excluding scan targets — allowed roots stay open.
        XCTAssertFalse(
            BlockedPaths.isBlocked(home.appendingPathComponent("Library/Caches/x.bin").path, home: home)
        )
    }
}
