import XCTest
@testable import Cleanora

final class CleanupReportTests: XCTestCase {
    private func outcome(
        category: ScanCategory,
        status: ItemOutcome.Status,
        bytes: Int64
    ) -> ItemOutcome {
        ItemOutcome(
            itemID: UUID(),
            name: "Item",
            category: category,
            path: "/tmp/item",
            status: status,
            bytesFreed: bytes,
            message: nil
        )
    }

    func testAggregates() {
        let report = CleanupReport(
            startedAt: Date(),
            finishedAt: Date().addingTimeInterval(3),
            outcomes: [
                outcome(category: .applicationCaches, status: .removed, bytes: 100),
                outcome(category: .applicationCaches, status: .partial, bytes: 50),
                outcome(category: .logs, status: .failed, bytes: 0),
                outcome(category: .trash, status: .removed, bytes: 25),
            ],
            freeSpaceBefore: 1000,
            freeSpaceAfter: 1175,
            scanResultID: nil
        )
        XCTAssertEqual(report.itemsRemoved, 2)
        XCTAssertEqual(report.partiallyRemoved, 1)
        XCTAssertEqual(report.failureCount, 1)
        XCTAssertEqual(report.bytesFreed, 175)
        XCTAssertEqual(report.freedBytes(in: .applicationCaches), 150)
        XCTAssertEqual(report.duration, 3, accuracy: 0.001)
    }

    func testHistoryEntryDropsZeroTotalsAndSortsCategories() {
        let report = CleanupReport(
            startedAt: Date(),
            finishedAt: Date(),
            outcomes: [
                outcome(category: .logs, status: .removed, bytes: 10),
                outcome(category: .applicationCaches, status: .removed, bytes: 90),
                outcome(category: .trash, status: .failed, bytes: 0),
            ],
            freeSpaceBefore: nil,
            freeSpaceAfter: nil,
            scanResultID: nil
        )
        let entry = CleanupHistoryEntry(from: report, appVersion: "0.1.0")
        XCTAssertEqual(entry.bytesFreed, 100)
        XCTAssertEqual(entry.itemsRemoved, 2)
        XCTAssertEqual(entry.categoryTotals.map(\.category), [.applicationCaches, .logs])
        XCTAssertEqual(entry.schemaVersion, CleanupHistoryEntry.schemaVersion)
    }
}
