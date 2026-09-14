import XCTest
@testable import Cleanora

final class ScanCategoryTests: XCTestCase {
    func testPhaseOneMatchesSpec() {
        XCTAssertEqual(
            ScanCategory.phaseOne,
            [.applicationCaches, .browserCaches, .temporaryFiles, .logs, .trash]
        )
    }

    func testEveryCategoryHasDisplayNameSymbolAndWhyText() {
        for category in ScanCategory.allCases {
            XCTAssertFalse(category.displayName.isEmpty, category.rawValue)
            XCTAssertFalse(category.symbolName.isEmpty, category.rawValue)
            XCTAssertFalse(category.whyText.isEmpty, "whyText required for \(category.rawValue)")
        }
    }

    func testOnlyTrashRequiresElevatedConfirmation() {
        for category in ScanCategory.allCases {
            XCTAssertEqual(category.requiresElevatedConfirmation, category == .trash)
        }
    }

    func testSortOrderIsStableAndComplete() {
        XCTAssertEqual(ScanCategory.scanOrder.count, ScanCategory.allCases.count)
        XCTAssertEqual(ScanCategory.scanOrder, ScanCategory.scanOrder.sorted { $0.sortOrder < $1.sortOrder })
    }

    // MARK: - Phase 3: .appLeftovers (M-06)

    func testAppLeftoversSortsAfterLargeFiles() {
        XCTAssertGreaterThan(ScanCategory.appLeftovers.sortOrder, ScanCategory.largeFiles.sortOrder)
        XCTAssertEqual(ScanCategory.scanOrder.last, .appLeftovers)
    }

    func testAppLeftoversHasItsOwnCopyAndSymbol() {
        XCTAssertNotEqual(ScanCategory.appLeftovers.whyText, "")
        XCTAssertEqual(ScanCategory.appLeftovers.displayName, "App Leftovers")
        XCTAssertFalse(ScanCategory.appLeftovers.symbolName.isEmpty)
    }

    func testAppLeftoversIsNotPartOfPhaseOne() {
        XCTAssertFalse(ScanCategory.phaseOne.contains(.appLeftovers))
        XCTAssertFalse(ScanCategory.appLeftovers.requiresElevatedConfirmation)
    }
}
