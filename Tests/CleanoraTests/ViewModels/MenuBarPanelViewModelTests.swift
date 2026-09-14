import XCTest
@testable import Cleanora

@MainActor
final class MenuBarPanelViewModelTests: XCTestCase {
    // MARK: - Junk estimate

    func testJunkEstimateSumsAllScanItems() {
        let result = VMFixtures.scanResult(items: [
            VMFixtures.item(name: "a", category: .applicationCaches, size: 100, risk: .safe),
            VMFixtures.item(name: "b", category: .logs, size: 250, risk: .review),
            VMFixtures.item(name: "c", category: .trash, size: 50, risk: .safe),
        ])
        XCTAssertEqual(MenuBarPanelViewModel.junkEstimateBytes(for: result), 400)
    }

    func testJunkEstimateWithoutScanIsZero() {
        XCTAssertEqual(MenuBarPanelViewModel.junkEstimateBytes(for: nil), 0)
    }

    // MARK: - Lines

    func testJunkLineBeforeFirstScan() {
        XCTAssertEqual(
            MenuBarPanelViewModel.junkLine(junkEstimateBytes: 0, hasScan: false),
            "No scan yet"
        )
    }

    func testJunkLineWithScanReportsBytes() {
        XCTAssertEqual(
            MenuBarPanelViewModel.junkLine(junkEstimateBytes: 500_000_000, hasScan: true),
            "500.0 MB cleanable"
        )
    }

    func testFreeSpaceLineIsNilWithoutOverview() {
        XCTAssertNil(MenuBarPanelViewModel.freeSpaceLine(for: nil))
    }

    func testFreeSpaceLineFormatsAvailableBytes() {
        let line = MenuBarPanelViewModel.freeSpaceLine(
            for: DiskOverview(totalCapacity: 500_000_000_000, availableForImportantUsage: 42_000_000_000)
        )
        XCTAssertEqual(line, "42.0 GB free")
    }

    func testLastCleanLineIsNilUntilACleanupExists() {
        XCTAssertNil(
            MenuBarPanelViewModel.lastCleanLine(
                for: nil,
                now: VMFixtures.fixedNow,
                calendar: VMFixtures.gregorianGMT,
                locale: VMFixtures.posixLocale,
                timeZone: VMFixtures.gregorianGMT.timeZone
            )
        )
    }

    func testLastCleanLineUsesTimestampFormat() {
        let line = MenuBarPanelViewModel.lastCleanLine(
            for: VMFixtures.fixedNow,
            now: VMFixtures.fixedNow,
            calendar: VMFixtures.gregorianGMT,
            locale: VMFixtures.posixLocale,
            timeZone: VMFixtures.gregorianGMT.timeZone
        )
        XCTAssertEqual(line, "Last cleaned: Today, 10:42 AM")
    }

    func testLastScanLineUsesTimestampFormat() {
        let line = MenuBarPanelViewModel.lastScanLine(
            for: VMFixtures.fixedNow.addingTimeInterval(-3600),
            now: VMFixtures.fixedNow,
            calendar: VMFixtures.gregorianGMT,
            locale: VMFixtures.posixLocale,
            timeZone: VMFixtures.gregorianGMT.timeZone
        )
        XCTAssertEqual(line, "Scanned Today, 9:42 AM")
    }

    // MARK: - Refresh wiring

    @MainActor
    func testRefreshLoadsAllLinesFromProviders() {
        let result = VMFixtures.scanResult(items: [
            VMFixtures.item(name: "a", category: .applicationCaches, size: 10, risk: .safe)
        ])
        var scanned: ScanResult?
        let viewModel = MenuBarPanelViewModel(
            loadLastScan: { scanned },
            loadDiskOverview: { DiskOverview(totalCapacity: 10, availableForImportantUsage: 1_000_000_000) },
            loadLastCleanupDate: { VMFixtures.fixedNow },
            startScanAction: {}
        )

        scanned = result
        viewModel.refresh(
            now: VMFixtures.fixedNow,
            calendar: VMFixtures.gregorianGMT,
            locale: VMFixtures.posixLocale,
            timeZone: VMFixtures.gregorianGMT.timeZone
        )

        XCTAssertTrue(viewModel.didLoad)
        XCTAssertEqual(viewModel.junkLine, "10 B cleanable")
        XCTAssertEqual(viewModel.lastCleanLine, "Last cleaned: Today, 10:42 AM")
        XCTAssertNotNil(viewModel.freeSpaceLine)
        XCTAssertNotNil(viewModel.lastScanLine)
    }
}
