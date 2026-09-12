import SwiftUI

/// U-13: shown when a scan or the dashboard detects missing Full Disk
/// Access. Factual, with the one action that fixes it — the open-settings
/// closure is injected via AppEnvironment's permission hook.
struct PermissionBanner: View {
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: Design.spacingM) {
            Image(systemName: "lock.shield")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access not granted")
                    .font(.headline)
                Text(
                    "Some locations couldn't be scanned, so results may be incomplete. "
                        + "Grant access under System Settings → Privacy & Security → Full Disk Access."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Design.spacingS)
            Button("Open System Settings", action: onOpenSettings)
                .accessibilityHint("Opens the Full Disk Access pane.")
        }
        .padding(Design.spacingM)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Design.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Design.cornerRadius)
                .strokeBorder(Color.orange.opacity(0.35))
        )
        .accessibilityElement(children: .contain)
    }
}
