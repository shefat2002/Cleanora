import SwiftUI

/// Phase-2 route placeholder (spec §12 — Xcode, Homebrew, npm, pip, Yarn,
/// Docker). Keeps the route table honest until DeveloperCleanupView lands.
struct DeveloperPlaceholderView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.spacingM) {
                Button {
                    environment.navigation.go(.dashboard)
                } label: {
                    Label("Dashboard", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back to dashboard")
                Text("Developer Cleanup")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, Design.spacingL)
            .padding(.vertical, Design.spacingM)

            Divider()

            EmptyStateView(
                systemImage: "hammer",
                title: "Coming in a later release",
                message: "Developer caches for Xcode, Homebrew, npm, pip, Yarn and Docker will be scanned and cleaned here. Nothing is selected automatically."
            )
        }
    }
}
