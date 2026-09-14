import Foundation
import Observation

/// Route-driven navigation state. Deliberately a single property: the app is
/// a linear Scan → Review → Clean → Verify flow with two auxiliary screens,
/// so a full NavigationPath would be machinery without a job.
@MainActor
@Observable
final class NavigationState {
    private(set) var route: ScreenRoute = .dashboard
    /// One-shot category the next Results appearance should expand and scroll
    /// to (M-03 "Review" from a suggestion). Consumed by ResultsView.
    private(set) var pendingHighlightedCategory: ScanCategory?

    func go(_ route: ScreenRoute) {
        pendingHighlightedCategory = nil
        self.route = route
    }

    /// Navigates and asks the destination to bring one category into view.
    func go(_ route: ScreenRoute, highlighting category: ScanCategory) {
        pendingHighlightedCategory = category
        self.route = route
    }

    /// Consumed exactly once by the destination screen.
    func takeHighlightedCategory() -> ScanCategory? {
        let category = pendingHighlightedCategory
        pendingHighlightedCategory = nil
        return category
    }
}
