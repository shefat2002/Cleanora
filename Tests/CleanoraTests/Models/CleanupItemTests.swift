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
        // The memberwise init guards with precondition (crash, not throw —
        // by design, it's a programmer error). The Codable path throws, and
        // testDecodingNeverRiskThrows proves it.
        XCTAssertFalse(RiskLevel.never.isPreselected)
    }

    func testDecodingNeverRiskThrows() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(CleanupItem.self, from: neverItemJSON())) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
        }
    }

    private func neverItemJSON() throws -> Data {
        let item = makeItem()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json["riskLevel"] = "never"
        return try JSONSerialization.data(withJSONObject: json)
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
