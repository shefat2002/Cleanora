import SwiftUI

/// Primary screen (spec §4): health headline, safe-to-clean total, one
/// primary action, last-scan line, per-category sizes. Minimal on purpose —
/// no competing buttons, no alarm colors.
struct DashboardView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: DashboardViewModel?
    @State private var suggestions: SuggestionsViewModel?

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
            if suggestions == nil {
                suggestions = SuggestionsViewModel(environment: environment)
            }
            viewModel?.refresh()
            suggestions?.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: Design.spacingM) {
            Spacer()
            Button {
                environment.navigation.go(.duplicates)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Duplicate finder")
            .accessibilityLabel("Duplicate finder")
            .accessibilityHint("Finds duplicate files in folders you choose. Nothing is scanned until you add a folder.")

            Button {
                environment.navigation.go(.uninstaller)
            } label: {
                Image(systemName: "minus.app")
            }
            .buttonStyle(.borderless)
            .help("Uninstaller")
            .accessibilityLabel("Uninstaller")
            .accessibilityHint("Lists installed apps and their leftover files.")

            Button {
                environment.navigation.go(.developer)
            } label: {
                Image(systemName: "hammer")
            }
            .buttonStyle(.borderless)
            .help("Developer cleanup")
            .accessibilityLabel("Developer cleanup")
            .accessibilityHint("Shows developer caches for Xcode, Node, Python, Homebrew and Docker.")

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
                    firstRunExplainer
                        .frame(maxWidth: Design.narrowColumnWidth)
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

                if let overview = viewModel.diskOverview {
                    DiskUsageChartView(
                        segments: DashboardViewModel.diskSegments(
                            scan: viewModel.lastScan,
                            overview: overview
                        ),
                        summaryLine: DashboardViewModel.diskSummaryLine(
                            for: overview,
                            scan: viewModel.lastScan
                        )
                    )
                    .frame(maxWidth: Design.narrowColumnWidth)
                }

                if let suggestions, !suggestions.isEmpty {
                    SuggestionsCardView(
                        recommendations: suggestions.recommendations,
                        onReview: { recommendation in
                            environment.navigation.go(
                                .results,
                                highlighting: recommendation.category
                            )
                        }
                    )
                    .frame(maxWidth: Design.narrowColumnWidth)
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

    /// First-run explainer (no scan yet): what a scan does and does not do.
    /// Informational only — no buttons, and no persisted first-launch flag;
    /// it simply disappears once a scan exists.
    private var firstRunExplainer: some View {
        VStack(alignment: .leading, spacing: Design.spacingM) {
            Text(DashboardViewModel.firstRunTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: Design.spacingXS) {
                ForEach(DashboardViewModel.firstRunPoints, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: Design.spacingS) {
                        Text("•")
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text(point)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        }
        .padding(Design.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: Design.cornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.cornerRadius)
                .strokeBorder(.quaternary)
        )
        .accessibilityElement(children: .contain)
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
