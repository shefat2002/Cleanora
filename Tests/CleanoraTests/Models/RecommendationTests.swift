import XCTest
@testable import Cleanora

/// M-03 model — a Recommendation is an inert suggestion card: identity,
/// copy, estimated size and the category it came from.
final class RecommendationTests: XCTestCase {
    func testIdentityIsStableWithinInstance() {
        let recommendation = Recommendation(
            title: "Old Xcode archives",
            detail: "detail",
            estimatedBytes: 600_000_000,
            category: .developerData
        )
        XCTAssertEqual(recommendation.id, recommendation.id)
    }

    func testCodableRoundTripPreservesAllFields() throws {
        let original = Recommendation(
            title: "Trash is filling up",
            detail: "12 GB sit in the Trash.",
            estimatedBytes: 12_000_000_000,
            category: .trash
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Recommendation.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.detail, original.detail)
        XCTAssertEqual(decoded.estimatedBytes, original.estimatedBytes)
        XCTAssertEqual(decoded.category, original.category)
    }
}
