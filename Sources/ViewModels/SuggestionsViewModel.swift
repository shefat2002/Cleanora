import Foundation
import Observation

/// Dashboard "Suggestions" card (M-03): turns the recommendation engine's
/// output over the last scan into a short, informational list. Rows never
/// select anything — "Review" only routes to Results with the category
/// section highlighted.
@MainActor
@Observable
final class SuggestionsViewModel {
    /// Maximum rows on the dashboard card; the engine may return more.
    nonisolated static let displayLimit = 4

    private(set) var recommendations: [Recommendation] = []

    var isEmpty: Bool { recommendations.isEmpty }

    private let loadLastScan: @MainActor () -> ScanResult?

    init(loadLastScan: @escaping @MainActor () -> ScanResult?) {
        self.loadLastScan = loadLastScan
    }

    convenience init(environment: AppEnvironment) {
        self.init(
            loadLastScan: { environment.lastScanResult ?? environment.scanHistoryStore.lastScan() }
        )
    }

    func refresh() {
        recommendations = Self.displayRows(for: loadLastScan())
    }

    // MARK: - Pure logic

    /// Filtering for the card: nothing without a scan, nothing the engine
    /// could not attach bytes to, duplicates collapsed, largest estimate
    /// first, capped at `displayLimit` so the dashboard stays one glance.
    nonisolated static func displayRows(
        for result: ScanResult?,
        engine: (ScanResult) -> [Recommendation] = { RecommendationEngine.recommendations(from: $0) },
        limit: Int = SuggestionsViewModel.displayLimit
    ) -> [Recommendation] {
        guard let result else { return [] }
        return engine(result)
            .filter { $0.estimatedBytes > 0 }
            .sorted {
                if $0.estimatedBytes != $1.estimatedBytes { return $0.estimatedBytes > $1.estimatedBytes }
                return $0.title < $1.title
            }
            .uniqued { "\($0.category.rawValue)|\($0.title)" }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// VoiceOver summary for one row.
    nonisolated static func rowAccessibilityLabel(for recommendation: Recommendation) -> String {
        "\(recommendation.title). \(recommendation.category.displayName). " +
            "\(recommendation.detail) " +
            "\(recommendation.estimatedBytes.formattedByteCount) estimated. " +
            "Review highlights this category in the results; nothing is selected."
    }
}

private extension Array {
    /// Order-preserving dedupe by a derived key.
    func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen: Set<Key> = []
        var result: [Element] = []
        result.reserveCapacity(count)
        for element in self {
            if seen.insert(key(element)).inserted {
                result.append(element)
            }
        }
        return result
    }
}
