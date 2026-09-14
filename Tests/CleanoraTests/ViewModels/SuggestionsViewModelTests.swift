import XCTest
@testable import Cleanora

final class SuggestionsViewModelTests: XCTestCase {
    private func recommendation(
        title: String,
        detail: String = "detail",
        bytes: Int64,
        category: ScanCategory = .developerData
    ) -> Recommendation {
        Recommendation(
            title: title,
            detail: detail,
            estimatedBytes: bytes,
            category: category
        )
    }

    // MARK: - Filtering

    func testNoScanYieldsNoRows() {
        XCTAssertTrue(
            SuggestionsViewModel.displayRows(for: nil, engine: { _ in
                [recommendation(title: "x", bytes: 5)]
            }).isEmpty
        )
    }

    func testRowsWithoutEstimatedBytesAreDropped() {
        let rows = SuggestionsViewModel.displayRows(
            for: VMFixtures.scanResult(items: []),
            engine: { _ in
                [
                    recommendation(title: "real", bytes: 4_000_000_000),
                    recommendation(title: "empty", bytes: 0),
                    recommendation(title: "negative", bytes: -5),
                ]
            }
        )
        XCTAssertEqual(rows.map(\.title), ["real"])
    }

    func testRowsAreSortedByEstimatedBytesDescending() {
        let rows = SuggestionsViewModel.displayRows(
            for: VMFixtures.scanResult(items: []),
            engine: { _ in
                [
                    recommendation(title: "small", bytes: 100),
                    recommendation(title: "huge", bytes: 9_000_000_000),
                    recommendation(title: "middle", bytes: 500_000_000),
                ]
            }
        )
        XCTAssertEqual(rows.map(\.title), ["huge", "middle", "small"])
    }

    func testDuplicateSuggestionsCollapseByCategoryAndTitle() {
        let rows = SuggestionsViewModel.displayRows(
            for: VMFixtures.scanResult(items: []),
            engine: { _ in
                [
                    recommendation(title: "Stale archives", bytes: 10),
                    recommendation(title: "Stale archives", bytes: 10),
                    recommendation(title: "Stale archives", bytes: 10, category: .logs),
                ]
            }
        )
        // Same title in another category is a different suggestion and stays.
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.category)), [.developerData, .logs])
    }

    func testDisplayLimitCapsTheCard() {
        let many = (0..<9).map {
            recommendation(title: "r\($0)", bytes: Int64($0) + 1)
        }
        let rows = SuggestionsViewModel.displayRows(
            for: VMFixtures.scanResult(items: []),
            engine: { _ in many }
        )
        XCTAssertEqual(rows.count, SuggestionsViewModel.displayLimit)
        // The cap keeps the largest estimates.
        XCTAssertEqual(rows.first?.title, "r8")
    }

    // MARK: - Instance behaviour

    @MainActor
    func testRefreshLoadsFromProvider() {
        let result = VMFixtures.scanResult(items: [])
        var stored: ScanResult?
        let viewModel = SuggestionsViewModel(loadLastScan: { stored })

        viewModel.refresh()
        XCTAssertTrue(viewModel.isEmpty)

        stored = result
        viewModel.refresh()
        XCTAssertFalse(viewModel.isEmpty)
    }

    // MARK: - Accessibility

    func testRowAccessibilityLabelNamesCategoryAndEstimate() {
        let label = SuggestionsViewModel.rowAccessibilityLabel(
            for: recommendation(title: "Old archives", detail: "Not touched in 90 days.", bytes: 2_000_000_000)
        )
        XCTAssertTrue(label.contains("Old archives"))
        XCTAssertTrue(label.contains("Not touched in 90 days."))
        XCTAssertTrue(label.contains("2.0 GB"))
        XCTAssertTrue(label.contains("Developer Data"), "VoiceOver must read the full category name")
        XCTAssertTrue(label.contains("Nothing is selected") || label.contains("highlights"))
    }
}
