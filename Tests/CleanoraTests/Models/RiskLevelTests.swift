import XCTest
@testable import Cleanora

final class RiskLevelTests: XCTestCase {
    func testSafeIsPreselectedAndReviewIsNot() {
        XCTAssertTrue(RiskLevel.safe.isPreselected)
        XCTAssertFalse(RiskLevel.review.isPreselected)
        XCTAssertFalse(RiskLevel.never.isPreselected)
    }

    func testSortOrderPutsSafeFirst() {
        XCTAssertTrue(RiskLevel.safe < RiskLevel.review)
        XCTAssertTrue(RiskLevel.review < RiskLevel.never)
    }

    func testDisplayNamesPresent() {
        for level in RiskLevel.allCases {
            XCTAssertFalse(level.displayName.isEmpty)
            XCTAssertFalse(level.symbolName.isEmpty)
        }
    }
}
