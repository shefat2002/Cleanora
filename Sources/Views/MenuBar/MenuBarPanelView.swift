import SwiftUI

/// The menu bar item's panel (M-01): free space, junk estimate, last-scan /
/// last-clean lines, one Scan action, Open and Quit. Compact by design —
/// this is a glanceable status, not a second dashboard. Hosted by
/// MenuBarController's NSPopover, which lives OUTSIDE any SwiftUI scene, so
/// window activation goes through AppEnvironment's captured handler instead
/// of the `openWindow` environment action (that only resolves scene-hosted).
struct MenuBarPanelView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: MenuBarPanelViewModel?

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .padding(Design.spacingL)
            }
        }
        .frame(width: 260)
        .task {
            if viewModel == nil {
                viewModel = MenuBarPanelViewModel(
                    loadLastScan: {
                        environment.lastScanResult ?? environment.scanHistoryStore.lastScan()
                    },
                    loadDiskOverview: { DiskInfoProvider().overview() },
                    loadLastCleanupDate: {
                        environment.scanHistoryStore.history(limit: 1).first?.date
                    },
                    openMainWindowAction: { environment.openMainWindow() },
                    startScanAction: { environment.navigation.go(.scan) }
                )
            }
            viewModel?.refresh()
        }
    }

    private func content(_ viewModel: MenuBarPanelViewModel) -> some View {
        VStack(alignment: .leading, spacing: Design.spacingS) {
            Text("Cleanora")
                .font(.headline)

            VStack(alignment: .leading, spacing: 3) {
                if let freeSpaceLine = viewModel.freeSpaceLine {
                    Text(freeSpaceLine)
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                }
                if let junkLine = viewModel.junkLine {
                    Text(junkLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let lastScanLine = viewModel.lastScanLine {
                    Text(lastScanLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let lastCleanLine = viewModel.lastCleanLine {
                    Text(lastCleanLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Divider()

            Button {
                viewModel.scanNow()
            } label: {
                Label("Scan Mac", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityHint("Opens the main window and starts a scan. Nothing is deleted during a scan.")

            Button {
                viewModel.openMainWindow()
            } label: {
                Label("Open Cleanora", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityHint("Opens the main window.")

            Divider()

            Button(role: .destructive) {
                viewModel.quit()
            } label: {
                Label("Quit Cleanora", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityHint("Quits Cleanora, including the menu bar item.")
        }
        .padding(Design.spacingM)
    }

    /// Matches WindowGroup(id:) in CleanoraApp; the captured openWindow
    /// handler targets this id.
    static let mainWindowID = "main"
}
