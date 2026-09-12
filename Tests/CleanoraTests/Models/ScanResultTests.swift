import XCTest
@testable import Cleanora

final class ScanResultTests: XCTestCase {
    private func item(
        _ name: String,
        category: ScanCategory,
        size: Int64,
        risk: RiskLevel
    ) -> CleanupItem {
        CleanupItem(
            name: name,
            category: category,
            path: URL(fileURLWithPath: "/tmp/\(name)"),
            size: size,
            riskLevel: risk,
            reason: "test",
            deletionMethod: .trashDirectory
        )
    }

    func testSelectedTotalsExcludeUnselected() {
        let safe = item("A", category: .applicationCaches, size: 100, risk: .safe)
        let review = item("B", category: .developerData, size: 200, risk: .review)
        let result = ScanResult(startedAt: Date(), finishedAt: Date().addingTimeInterval(5), items: [safe, review])
        XCTAssertEqual(result.selectedBytes, 100, "review items are not preselected")
        XCTAssertEqual(result.selectedItems.map(\.name), ["A"])
    }

    func testItemsInCategory() {
        let a = item("A", category: .logs, size: 1, risk: .safe)
        let b = item("B", category: .logs, size: 2, risk: .safe)
        let result = ScanResult(startedAt: Date(), finishedAt: Date(), items: [a, b])
        XCTAssertEqual(result.items(in: .logs).count, 2)
        XCTAssertEqual(result.items(in: .trash).count, 0)
    }

    func testCodableRoundTrip() throws {
        let a = item("A", category: .logs, size: 1, risk: .safe)
        let result = ScanResult(
            startedAt: Date(timeIntervalSince1970: 1_000),
            finishedAt: Date(timeIntervalSince1970: 1_005),
            items: [a]
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ScanResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }
}

final class ScanProgressTests: XCTestCase {
    private let key = ScannerKey(id: .logs)

    func testOverallFractionIgnoresDisabledScanners() {
        var progress = ScanProgress()
        progress.states[key] = .completed(totalBytes: 10, itemCount: 1)
        XCTAssertEqual(progress.overallFraction(totalScanners: 5), 0.2, accuracy: 0.0001)
        XCTAssertEqual(progress.overallFraction(totalScanners: 0), 0)
    }

    func testDiscoveredBytesSumsRunningAndCompleted() {
        var progress = ScanProgress()
        progress.states[ScannerKey(id: .logs)] = .running(bytesScanned: 40, itemsFound: 2)
        progress.states[ScannerKey(id: .trash)] = .completed(totalBytes: 60, itemCount: 3)
        XCTAssertEqual(progress.discoveredBytes, 100)
    }

    func testCompletedCountCountsTerminalStates() {
        var progress = ScanProgress()
        progress.states[ScannerKey(id: .logs)] = .completed(totalBytes: 1, itemCount: 1)
        progress.states[ScannerKey(id: .trash)] = .skipped(.pathNotFound("missing"))
        progress.states[ScannerKey(id: .temporaryFiles)] = .running(bytesScanned: 1, itemsFound: 1)
        XCTAssertEqual(progress.completedCount, 2)
    }
}
