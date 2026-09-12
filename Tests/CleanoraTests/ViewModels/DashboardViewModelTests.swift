import XCTest
@testable import Cleanora

@MainActor
final class DashboardViewModelTests: XCTestCase {
    func testSafeToCleanBytesCountsOnlySafeItems() {
        let result = VMFixtures.scanResult(items: [
            VMFixtures.item(name: "cache", category: .applicationCaches, size: 8_400, risk: .safe),
            VMFixtures.item(name: "temp", category: .temporaryFiles, size: 2_100, risk: .safe),
            VMFixtures.item(name: "archive", category: .largeFiles, size: 50_000, risk: .review),
        ])
        XCTAssertEqual(DashboardViewModel.safeToCleanBytes(for: result), 10_500)
        XCTAssertEqual(DashboardViewModel.safeToCleanBytes(for: nil), 0)
    }

    func testCategoryRowsHideEmptyCategoriesAndSortBySpecOrder() {
        let result = VMFixtures.scanResult(items: [
            VMFixtures.item(name: "log", category: .logs, size: 100, risk: .safe),
            VMFixtures.item(name: "trash", category: .trash, size: 300, risk: .safe),
            VMFixtures.item(name: "cache", category: .applicationCaches, size: 200, risk: .safe),
        ])
        let rows = DashboardViewModel.categoryRows(for: result)
        XCTAssertEqual(rows.map(\.category), [.applicationCaches, .logs, .trash])
        XCTAssertEqual(DashboardViewModel.categoryRows(for: nil), [])
    }

    func testHealthHeadlineThresholds() {
        XCTAssertTrue(DashboardViewModel.healthHeadline(for: 0, hasScan: false) == "Ready")
        XCTAssertEqual(DashboardViewModel.healthHeadline(for: 0, hasScan: true), "Healthy")
        XCTAssertEqual(
            DashboardViewModel.healthHeadline(for: 4_999_999_999, hasScan: true),
            "Healthy"
        )
        XCTAssertEqual(
            DashboardViewModel.healthHeadline(for: 10_000_000_000, hasScan: true),
            "Could be cleaner"
        )
        XCTAssertEqual(
            DashboardViewModel.healthHeadline(for: 30_000_000_000, hasScan: true),
            "Needs attention"
        )
    }

    func testRefreshLoadsProvidersAndFormatsLastScanLine() {
        // Finished at fixedNow + 5 minutes → "Today, 10:47 AM".
        let result = VMFixtures.scanResult(
            startedAt: VMFixtures.fixedNow.addingTimeInterval(5 * 60 - 5),
            items: [
                VMFixtures.item(name: "cache", category: .applicationCaches, size: 6_000_000_000, risk: .safe),
            ]
        )
        let viewModel = DashboardViewModel(
            loadLastScan: { result },
            loadDiskOverview: {
                DiskOverview(totalCapacity: 500_000_000_000, availableForImportantUsage: 87_400_000_000)
            },
            permissionCheck: { false }
        )

        viewModel.refresh(
            now: VMFixtures.fixedNow,
            calendar: VMFixtures.gregorianGMT,
            locale: VMFixtures.posixLocale,
            timeZone: TimeZone(identifier: "GMT")!
        )

        XCTAssertEqual(viewModel.headline, "Could be cleaner")
        XCTAssertEqual(viewModel.lastScanLine, "Last scan: Today, 10:47 AM", "scan finished at 1000+5s ≈ fixedNow+5min")
        XCTAssertEqual(viewModel.freeSpaceLine, "87.4 GB available")
        XCTAssertFalse(viewModel.hasFullDiskAccess)
        XCTAssertTrue(viewModel.hasScan)
        XCTAssertEqual(viewModel.categoryRows.map(\.category), [.applicationCaches])
    }

    func testRefreshWithoutScanStaysInReadyState() {
        let viewModel = DashboardViewModel(
            loadLastScan: { nil },
            loadDiskOverview: { nil },
            permissionCheck: { true }
        )
        viewModel.refresh(now: VMFixtures.fixedNow, calendar: VMFixtures.gregorianGMT, locale: VMFixtures.posixLocale, timeZone: TimeZone(identifier: "GMT")!)
        XCTAssertEqual(viewModel.headline, "Ready")
        XCTAssertNil(viewModel.lastScanLine)
        XCTAssertNil(viewModel.freeSpaceLine)
        XCTAssertTrue(viewModel.hasFullDiskAccess)
        XCTAssertFalse(viewModel.hasScan)
    }
}
