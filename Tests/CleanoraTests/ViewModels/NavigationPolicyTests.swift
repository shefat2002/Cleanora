import XCTest
@testable import Cleanora

/// NavigationPolicy's refusal matrix: what ⌘R/⌘1 (and every other
/// navigation call) may do while a scan or a clean is in flight. Pins the
/// two verified regressions — a second scan started mid-scan (the per-VM
/// idle guard is per-instance), and escaping the non-dismissable cleaning
/// screen mid-clean.
final class NavigationPolicyTests: XCTestCase {
    /// Every route, so a matrix hole cannot hide behind an untested pair.
    private let allRoutes: [ScreenRoute] = [
        .dashboard, .scan, .results, .cleaning, .completion,
        .history, .developer, .duplicates, .uninstaller,
    ]

    // MARK: Idle

    func testIdleAllowsEveryTransition() {
        for current in allRoutes {
            for destination in allRoutes {
                XCTAssertFalse(
                    NavigationPolicy.isBlocked(
                        current: current, destination: destination,
                        isScanRunning: false, isCleanRunning: false
                    ),
                    "idle: \(current) → \(destination) must be allowed"
                )
            }
        }
    }

    // MARK: Clean in flight

    func testCleanRunningBlocksEveryDestinationExceptCleaning() {
        for current in allRoutes {
            for destination in allRoutes where destination != .cleaning {
                XCTAssertTrue(
                    NavigationPolicy.isBlocked(
                        current: current, destination: destination,
                        isScanRunning: false, isCleanRunning: true
                    ),
                    "clean in flight: \(current) → \(destination) must be refused"
                )
            }
        }
    }

    func testCleanRunningKeepsTheStagingHandoffIntoCleaningOpen() {
        // beginCleaning → go(.cleaning) must not be refused by the very
        // flag it just set, from any screen that can stage a clean.
        for current in allRoutes {
            XCTAssertFalse(
                NavigationPolicy.isBlocked(
                    current: current, destination: .cleaning,
                    isScanRunning: false, isCleanRunning: true
                ),
                "clean staging: \(current) → .cleaning must pass"
            )
        }
    }

    // MARK: Scan in flight

    func testScanRunningBlocksNavigationIntoScanFromAnywhere() {
        for current in allRoutes {
            XCTAssertTrue(
                NavigationPolicy.isBlocked(
                    current: current, destination: .scan,
                    isScanRunning: true, isCleanRunning: false
                ),
                "scan in flight: \(current) → .scan would start a second scan"
            )
        }
    }

    func testScanRunningBlocksLeavingScan() {
        for destination in allRoutes {
            XCTAssertTrue(
                NavigationPolicy.isBlocked(
                    current: .scan, destination: destination,
                    isScanRunning: true, isCleanRunning: false
                ),
                "scan in flight: .scan → \(destination) would abandon the running scan"
            )
        }
    }

    func testScanRunningLeavesOrdinaryBrowsingAlone() {
        // A background scheduled scan must not freeze dashboard / settings /
        // history navigation — only .scan edges are guarded.
        let browsing = allRoutes.filter { $0 != .scan }
        for current in browsing {
            for destination in browsing {
                XCTAssertFalse(
                    NavigationPolicy.isBlocked(
                        current: current, destination: destination,
                        isScanRunning: true, isCleanRunning: false
                    ),
                    "scan in flight elsewhere: \(current) → \(destination) must stay free"
                )
            }
        }
    }
}
