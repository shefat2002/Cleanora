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

    // MARK: Disk chart segments (P-10)

    private let overview = DiskOverview(
        totalCapacity: 500_000_000_000,
        availableForImportantUsage: 87_400_000_000
    )

    func testDiskSegmentsWithoutScanShowOnlyUsedAndFree() {
        let segments = DashboardViewModel.diskSegments(scan: nil, overview: overview)

        XCTAssertEqual(segments.map(\.label), ["Used space", "Free space"])
        XCTAssertEqual(segments[0].bytes, 500_000_000_000 - 87_400_000_000)
        XCTAssertEqual(segments[1].bytes, 87_400_000_000)
    }

    func testDiskSegmentsRequireAnOverview() {
        XCTAssertTrue(DashboardViewModel.diskSegments(scan: nil, overview: nil).isEmpty)
        XCTAssertTrue(
            DashboardViewModel.diskSegments(
                scan: nil,
                overview: DiskOverview(totalCapacity: 0, availableForImportantUsage: 0)
            ).isEmpty,
            "an unreadable probe renders the placeholder, not a fake bar"
        )
    }

    func testDiskSegmentsStackJunkThenUsedThenFreeContiguously() {
        let scan = VMFixtures.scanResult(items: [
            VMFixtures.item(name: "cache", category: .applicationCaches, size: 6_000_000_000, risk: .safe),
            VMFixtures.item(name: "log", category: .logs, size: 1_000_000_000, risk: .safe),
        ])
        let segments = DashboardViewModel.diskSegments(scan: scan, overview: overview)

        XCTAssertEqual(segments.map(\.label), [
            "Application Caches (cleanable)",
            "Old Logs (cleanable)",
            "Used space",
            "Free space",
        ])
        // Contiguity: each segment starts where the previous one ends.
        for (previous, next) in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(next.startBytes, previous.endBytes)
        }
        XCTAssertEqual(segments[0].startBytes, 0)
        XCTAssertEqual(segments[2].bytes, (500_000_000_000 - 87_400_000_000) - 7_000_000_000, "used excludes the measured junk")
        XCTAssertEqual(segments[3].bytes, 87_400_000_000)
    }

    func testDiskSegmentsClampUsedInsteadOfGoingNegative() {
        // Junk larger than measured used space (external volumes, stale
        // probes): the bar must never contain a negative segment.
        let scan = VMFixtures.scanResult(items: [
            VMFixtures.item(name: "cache", category: .applicationCaches, size: 600_000_000_000, risk: .safe),
        ])
        let segments = DashboardViewModel.diskSegments(scan: scan, overview: overview)

        XCTAssertTrue(segments.contains(where: { $0.kind == .junk(.applicationCaches) }))
        XCTAssertFalse(segments.contains(where: { $0.kind == .otherUsed }))
    }

    func testDiskSegmentsIncludeReviewOnlyLargeFilesInJunkShare() {
        // Large review files belong to the junk share too — the chart shows
        // what the scan found; selection happens later on Results.
        let scan = VMFixtures.scanResult(items: [
            VMFixtures.item(name: "big", category: .largeFiles, size: 2_000_000_000, risk: .review),
        ])
        let segments = DashboardViewModel.diskSegments(scan: scan, overview: overview)
        XCTAssertEqual(segments.first?.label, "Large Files (cleanable)")
    }

    func testDiskSummaryLineMentionsFreeAndCleanable() {
        let scan = VMFixtures.scanResult(items: [
            VMFixtures.item(name: "cache", category: .applicationCaches, size: 6_000_000_000, risk: .safe),
        ])
        XCTAssertEqual(
            DashboardViewModel.diskSummaryLine(for: overview, scan: scan),
            "87.4 GB free of 500.0 GB, 6.0 GB cleanable"
        )
        XCTAssertEqual(
            DashboardViewModel.diskSummaryLine(for: overview, scan: nil),
            "87.4 GB free of 500.0 GB"
        )
        XCTAssertNil(DashboardViewModel.diskSummaryLine(for: nil, scan: nil))
    }

    // MARK: First-run explainer copy

    func testFirstRunCopyIsPresentAndNeverPromisesNumbers() {
        // Headline numbers stay measured (`ScanResult`); explainer copy is
        // strictly qualitative — a digit here would promise a byte amount.
        XCTAssertFalse(DashboardViewModel.firstRunTitle.isEmpty)
        XCTAssertEqual(DashboardViewModel.firstRunPoints.count, 3)
        for point in DashboardViewModel.firstRunPoints {
            XCTAssertFalse(point.isEmpty)
        }
        XCTAssertFalse(
            ([DashboardViewModel.firstRunTitle] + DashboardViewModel.firstRunPoints)
                .joined()
                .contains(where: \.isNumber),
            "explainer copy must not promise byte amounts"
        )
    }

    func testFirstRunCopyDoesNotPromiseRecoverability() {
        // Some removable items (Trash, containers) are gone for good, so the
        // copy may never claim recovery.
        let copy = ([DashboardViewModel.firstRunTitle] + DashboardViewModel.firstRunPoints)
            .joined(separator: " ")
            .lowercased()
        XCTAssertFalse(copy.contains("recover"))
        XCTAssertFalse(copy.contains("restor"), "covers restorable/restored")
        XCTAssertFalse(copy.contains("undo"))
    }
}
