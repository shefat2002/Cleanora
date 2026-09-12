import SwiftUI

/// Primary screen (spec §4): health headline, safe-to-clean total, one
/// primary action, last-scan line, per-category sizes. Minimal on purpose —
/// no competing buttons, no alarm colors.
struct DashboardView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: DashboardViewModel?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if viewModel == nil {
                viewModel = DashboardViewModel(environment: environment)
            }
            viewModel?.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: Design.spacingM) {
            Spacer()
            Button {
                environment.navigation.go(.history)
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Cleanup history")
            .accessibilityLabel("Cleanup history")
            .accessibilityHint("Shows previous cleanups.")

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
            .accessibilityHint("Opens Cleanora settings.")
        }
        .font(.title3)
        .padding(.horizontal, Design.spacingL)
        .padding(.top, Design.spacingM)
    }

    private func content(_ viewModel: DashboardViewModel) -> some View {
        ScrollView {
            VStack(spacing: Design.spacingL) {
                if !viewModel.hasFullDiskAccess {
                    PermissionBanner {
                        environment.openFullDiskAccessSettings()
                    }
                }

                VStack(spacing: Design.spacingXS) {
                    Text("Your Mac is")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(viewModel.headline)
                        .font(.system(size: 40, weight: .bold))
                }
                .accessibilityElement(children: .combine)

                if viewModel.hasScan {
                    VStack(spacing: 2) {
                        Text(viewModel.safeToCleanBytes.formattedByteCount)
                            .font(.system(size: 56, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                        Text("Safe to clean")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(viewModel.safeToCleanBytes.formattedByteCount) safe to clean")
                } else {
                    Text("Run your first scan to see what can be cleaned.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let freeSpaceLine = viewModel.freeSpaceLine {
                    Text(freeSpaceLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                PrimaryActionButton(
                    title: "Scan Mac",
                    systemImage: "magnifyingglass",
                    hint: "Scans caches, temporary files, logs and the Trash. Nothing is deleted during a scan."
                ) {
                    environment.navigation.go(.scan)
                }

                if let lastScanLine = viewModel.lastScanLine {
                    Text(lastScanLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !viewModel.categoryRows.isEmpty {
                    categoryRows(viewModel)
                }
            }
            .padding(Design.spacingXL)
            .frame(maxWidth: Design.contentWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private func categoryRows(_ viewModel: DashboardViewModel) -> some View {
        VStack(spacing: 0) {
            ForEach(viewModel.categoryRows) { row in
                HStack(spacing: Design.spacingM) {
                    CategoryIcon(category: row.category, size: 26)
                    Text(row.category.displayName)
                        .font(.body)
                    Spacer()
                    Text(row.bytes.formattedByteCount)
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                }
                .padding(.vertical, Design.spacingS)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.category.displayName), \(row.bytes.formattedByteCount)")

                Divider()
                    .opacity(0.5)
            }
        }
        .frame(maxWidth: Design.narrowColumnWidth)
    }
}
