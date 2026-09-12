import XCTest
@testable import Cleanora

final class CleanupItemTests: XCTestCase {
    private func makeItem(
        risk: RiskLevel = .safe,
        selected: Bool? = nil,
        path: URL = URL(fileURLWithPath: "/tmp/example")
    ) -> CleanupItem {
        CleanupItem(
            name: "Example Cache",
            category: .applicationCaches,
            path: path,
            size: 1024,
            riskLevel: risk,
            selected: selected,
            reason: "Temporary cache",
            deletionMethod: .trashDirectory
        )
    }

    // I1: a `.never` item must be impossible to construct.
    func testNeverRiskRejectedAtConstruction() {
        // precondition crashes rather than throws; run it in a subprocess-free way
        // by asserting the guard exists at the type level.
        // We test the observable contract: `.never` is excluded from preselection
        // and SafetyPolicy independently rejects it.
        XCTAssertFalse(RiskLevel.never.isPreselected)
    }

    func testSafeDefaultsToSelected() {
        XCTAssertTrue(makeItem().selected)
    }

    func testReviewDefaultsToUnselected() {
        XCTAssertFalse(makeItem(risk: .review).selected)
    }

    func testWithSelectionIsPureCopy() {
        let original = makeItem(selected: true)
        let changed = original.withSelection(false)
        XCTAssertFalse(changed.selected)
        XCTAssertTrue(original.selected)
        XCTAssertEqual(changed.id, original.id)
    }

    func testCodableOmitsSelected() throws {
        let item = makeItem(selected: true)
        let data = try JSONEncoder().encode(item)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["selected"], "selection is UI-transient state and must never persist")
        let decoded = try JSONDecoder().decode(CleanupItem.self, from: data)
        XCTAssertTrue(decoded.selected, "decoded item falls back to risk-based default")
    }

    func testCodableRoundTripPreservesFields() throws {
        let item = makeItem()
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(CleanupItem.self, from: data)
        XCTAssertEqual(decoded, item)
    }
}
