import XCTest
@testable import Cleanora

/// App-layer flow glue: scan finish → last-scan persistence, cleanup finish →
/// history write-back (QA gate found these untested).
@MainActor
final class AppEnvironmentFlowTests: TempHomeTestCase {
    private func makeEnvironment() -> AppEnvironment {
        AppEnvironment(
            scanEnvironment: environment,
            permissionProbe: PermissionProbe(
                hasFullDiskAccess: { true },
                openFullDiskAccessSettings: {}
            )
        )
    }

    private func makeResult(selectedBytes: Int64) -> ScanResult {
        let item = CleanupItem(
            name: "Cache", category: .applicationCaches,
            path: tempHome.appendingPathComponent("Library/Caches/com.example"),
            size: selectedBytes, riskLevel: .safe, reason: "test",
            deletionMethod: .trashDirectory
        )
        return ScanResult(
            startedAt: Date(), finishedAt: Date().addingTimeInterval(2),
            items: [item]
        )
    }

    func testFinishScanPersistsLastScan() {
        let env = makeEnvironment()
        let result = makeResult(selectedBytes: 500)
        env.finishScan(result)
        let persisted = env.scanHistoryStore.lastScan()
        XCTAssertEqual(persisted?.id, result.id)
    }

    func testFinishCleanupAppendsHistoryWhenKeepHistoryOn() {
        let env = makeEnvironment()
        XCTAssertTrue(env.preferences.value.keepCleanupHistory)
        let report = CleanupReport(
            startedAt: Date(), finishedAt: Date(),
            outcomes: [ItemOutcome(
                itemID: UUID(), name: "Cache", category: .applicationCaches,
                path: "/tmp/x", status: .removed, bytesFreed: 100
            )],
            freeSpaceBefore: nil, freeSpaceAfter: nil, scanResultID: nil
        )
        env.finishCleanup(report)
        XCTAssertEqual(env.scanHistoryStore.history(limit: 10).count, 1)
        XCTAssertEqual(env.scanHistoryStore.history().first?.bytesFreed, 100)
    }

    func testFinishCleanupSkipsHistoryWhenKeepHistoryOff() {
        let env = makeEnvironment()
        env.preferences.update { $0.keepCleanupHistory = false }
        let report = CleanupReport(
            startedAt: Date(), finishedAt: Date(),
            outcomes: [ItemOutcome(
                itemID: UUID(), name: "Cache", category: .applicationCaches,
                path: "/tmp/x", status: .removed, bytesFreed: 100
            )],
            freeSpaceBefore: nil, freeSpaceAfter: nil, scanResultID: nil
        )
        env.finishCleanup(report)
        XCTAssertTrue(env.scanHistoryStore.history().isEmpty)
    }

    func testFinishCleanupIgnoresEmptyOutcomeReports() {
        let env = makeEnvironment()
        let report = CleanupReport(
            startedAt: Date(), finishedAt: Date(), outcomes: [],
            freeSpaceBefore: nil, freeSpaceAfter: nil, scanResultID: nil
        )
        env.finishCleanup(report)
        XCTAssertTrue(env.scanHistoryStore.history().isEmpty)
    }
}
