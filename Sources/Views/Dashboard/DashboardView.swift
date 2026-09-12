import SwiftUI

/// Primary screen: health headline, safe-to-clean total, single action.
struct DashboardView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Your Mac is")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Ready")
                .font(.largeTitle.bold())
            Spacer()
            Text("Run your first scan to see what can be cleaned.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
