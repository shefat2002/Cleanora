import Foundation

/// Navigation destinations rendered by RootView.
enum ScreenRoute: Hashable {
    case dashboard
    case scan
    case results
    case cleaning
    case completion
    case history
    case developer
    case duplicates   // Phase 3 (M-04)
    case uninstaller  // Phase 3 (M-06)
}
