import SwiftUI

/// Renders exactly one screen, switched on the navigation route. The linear
/// Scan → Review → Clean → Verify flow lives in AppEnvironment + the view
/// models; this type only maps route → view.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ZStack {
            switch environment.navigation.route {
            case .dashboard: DashboardView().transition(.opacity)
            case .scan: ScanProgressView().transition(.opacity)
            case .results: ResultsView().transition(.opacity)
            case .cleaning: CleaningView().transition(.opacity)
            case .completion: CompletionView().transition(.opacity)
            case .history: HistoryView().transition(.opacity)
            case .developer: DeveloperCleanupView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: environment.navigation.route)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
