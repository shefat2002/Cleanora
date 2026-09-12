import Foundation
import Observation

/// Route-driven navigation state. Deliberately a single property: the app is
/// a linear Scan → Review → Clean → Verify flow with two auxiliary screens,
/// so a full NavigationPath would be machinery without a job.
@MainActor
@Observable
final class NavigationState {
    private(set) var route: ScreenRoute = .dashboard

    func go(_ route: ScreenRoute) {
        self.route = route
    }
}
