import XCTest
@testable import Cleanora

final class CompletionViewModelTests: XCTestCase {
    private func makeReport(
        outcomes: [ItemOutcome],
        freeSpaceAfter: Int64?
    ) -> CleanupReport {
        CleanupReport(
            startedAt: Date(timeIntervalSince1970: 1_789_284_120),
            finishedAt: Date(timeIntervalSince1970: 1_789_284_150),
            outcomes: outcomes,
            freeSpaceBefore: 87_400_000_000,
            freeSpaceAfter: freeSpaceAfter,
            scanResultID: UUID()
        )
    }

    private func item(_ name: String, category: ScanCategory, size: Int64) -> CleanupItem {
        VMFixtures.item(name: name, category: category, size: size, risk: .safe)
    }

    func testNumbersComeFromTheMeasuredReportOnly() {
        let cache = item("cache", category: .applicationCaches, size: 8_000)
        let temp = item("temp", category: .temporaryFiles, size: 1_700)
        let log = item("log", category: .logs, size: 800)
        let report = makeReport(
            outcomes: [
                VMFixtures.outcome(for: cache, status: .removed, bytesFreed: 8_200),
                VMFixtures.outcome(for: temp, status: .removed, bytesFreed: 1_700),
                VMFixtures.outcome(for: log, status: .failed, bytesFreed: 0, message: "in use"),
            ],
            freeSpaceAfter: 98_300_000_000
        )
        let model = CompletionViewModel(report: report, freeSpaceAfter: report.freeSpaceAfter)

        XCTAssertEqual(model.bytesFreed, 9_900, "measured bytes only")
        XCTAssertEqual(model.categoryRows.map(\.category), [.applicationCaches, .temporaryFiles], "failed category is absent (0 bytes)")
        XCTAssertEqual(model.categoryRows.map(\.bytes), [8_200, 1_700])
        XCTAssertEqual(model.itemsRemoved, 2)
        XCTAssertEqual(model.failureCount, 1)
        XCTAssertEqual(model.failureLine, "1 item couldn't be removed.")
        XCTAssertEqual(model.newFreeSpaceLine, "You now have 98.3 GB available.")
    }

    func testCategoryRowsOmitZeroByteCategoriesInSpecOrder() {
        let trash = item("trash", category: .trash, size: 100)
        let report = makeReport(
            outcomes: [VMFixtures.outcome(for: trash, status: .partial, bytesFreed: 100)],
            freeSpaceAfter: nil
        )
        let model = CompletionViewModel(report: report, freeSpaceAfter: nil)
        XCTAssertEqual(model.categoryRows.map(\.category), [.trash])
        XCTAssertNil(model.newFreeSpaceLine, "no invented free-space line")
    }

    func testPluralizationLines() {
        XCTAssertEqual(CompletionViewModel.itemsRemovedLine(count: 0), "No items removed")
        XCTAssertEqual(CompletionViewModel.itemsRemovedLine(count: 1), "1 item removed")
        XCTAssertEqual(CompletionViewModel.itemsRemovedLine(count: 2481), "2481 items removed")
        XCTAssertNil(CompletionViewModel.failureLine(count: 0))
        XCTAssertEqual(CompletionViewModel.failureLine(count: 3), "3 items couldn't be removed.")
    }

    func testFreedLineUsesFormattedBytes() {
        let cache = item("cache", category: .applicationCaches, size: 12_700_000_000)
        let report = makeReport(
            outcomes: [VMFixtures.outcome(for: cache, status: .removed, bytesFreed: 12_700_000_000)],
            freeSpaceAfter: nil
        )
        let model = CompletionViewModel(report: report, freeSpaceAfter: nil)
        XCTAssertEqual(model.freedLine, "12.7 GB freed")
        XCTAssertEqual(model.headline, "Your Mac is cleaner")
    }
}
