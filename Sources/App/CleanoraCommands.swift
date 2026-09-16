import SwiftUI

/// Minimal app menu (UX quick wins): the two navigation actions that are
/// safe from any state. Deliberately NO shortcuts into .results/.cleaning/
/// .completion — routing to Results with no scan leaves the screen stuck
/// on its loading spinner (ResultsView does have an EmptyStateView, but it
/// is unreachable without lastScanResult: with no result the view model
/// never builds and the spinner never resolves).
struct CleanoraCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        CommandMenu("Cleanora") {
            Button("Scan Mac") { environment.navigation.go(.scan) }
                .keyboardShortcut("r", modifiers: .command)
            Button("Dashboard") { environment.navigation.go(.dashboard) }
                .keyboardShortcut("1", modifiers: .command)
        }
    }
}
