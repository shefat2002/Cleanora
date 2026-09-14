import Foundation

/// M-03 — one dashboard suggestion. Produced ONLY by
/// `RecommendationEngine.recommendations(from:)` from a finished `ScanResult`.
/// A recommendation is an inert card: it is never auto-selected, never turned
/// into a `CleanupItem`, and never cleaned on its own — acting on one always
/// routes back through the user's explicit review.
public struct Recommendation: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let title: String
    public let detail: String
    public let estimatedBytes: Int64
    /// The scan category the estimate was derived from — lets the card link
    /// to the matching Results section.
    public let category: ScanCategory

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        estimatedBytes: Int64,
        category: ScanCategory
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.estimatedBytes = estimatedBytes
        self.category = category
    }
}
