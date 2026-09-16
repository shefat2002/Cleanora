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

    /// Answers "may this transition happen right now?" — installed by
    /// AppEnvironment so the refusal reads the live in-flight flags (see
    /// NavigationPolicy) without this state owning the environment (weak
    /// closure, no retain cycle). nil = unrestricted, so plain construction
    /// (unit tests) navigates exactly as before.
    var mayNavigate: (@MainActor (_ current: ScreenRoute, _ destination: ScreenRoute) -> Bool)?

    func go(_ route: ScreenRoute) {
        guard mayNavigate?(self.route, route) ?? true else { return }
        pendingHighlightedCategory = nil
        self.route = route
    }

    /// Navigates and asks the destination to bring one category into view.
    func go(_ route: ScreenRoute, highlighting category: ScanCategory) {
        guard mayNavigate?(self.route, route) ?? true else { return }
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
