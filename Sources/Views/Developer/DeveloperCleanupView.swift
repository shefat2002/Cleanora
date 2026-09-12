import SwiftUI

/// Spec §12: developer caches grouped by tool — Xcode (DerivedData, Archives,
/// Device Support), Node (npm, Yarn), Python (pip), Homebrew, Docker. Every
/// row is review-style (nothing preselected); Docker rows lead with their
/// reason text instead of a bare path.
struct DeveloperCleanupView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: DeveloperCleanupViewModel?
    @State private var whyItem: CleanupItem?
    @State private var confirmSheetVisible = false

    var body: some View {
        Group {
            if let viewModel {
                if viewModel.isEmpty {
                    emptyState
                } else {
                    content(viewModel)
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard viewModel == nil, let result = environment.lastScanResult else { return }
            viewModel = DeveloperCleanupViewModel(result: result)
        }
        .sheet(item: $whyItem) { item in
            WhyInfoSheet(category: item.category, item: item)
        }
        .sheet(isPresented: $confirmSheetVisible) {
            if let viewModel {
                ConfirmCleanSheet(selection: viewModel) { request in
                    environment.beginCleaning(request)
                    environment.navigation.go(.cleaning)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            header(nil)
            Divider()
            VStack(spacing: Design.spacingM) {
                if environment.lastScanResult == nil {
                    EmptyStateView(
                        systemImage: "hammer",
                        title: "No scan yet",
                        message: "Developer caches are scanned when “Developer caches” is on in Settings, then listed here — nothing is selected automatically."
                    )
                } else {
                    EmptyStateView(
                        systemImage: "hammer",
                        title: "No developer caches found",
                        message: "Either the tools aren't installed or “Developer caches” was off during the last scan. Turn it on in Settings and scan again."
                    )
                }
                SettingsLink {
                    Label("Open Settings", systemImage: "gearshape")
                }
                .accessibilityHint("Opens Cleanora settings.")
            }
        }
    }

    private func content(_ viewModel: DeveloperCleanupViewModel) -> some View {
        VStack(spacing: 0) {
            header(viewModel)
            Divider()
            ScrollView {
                LazyVStack(spacing: Design.spacingM) {
                    ForEach(viewModel.groups) { group in
                        toolGroupSection(viewModel, group: group)
                    }
                }
                .padding(Design.spacingL)
                .frame(maxWidth: Design.contentWidth)
                .frame(maxWidth: .infinity)
            }
            Divider()
            SelectionSummaryBar(
                selectedBytes: viewModel.selectedBytes,
                selectedCount: viewModel.selectedCount,
                canClean: viewModel.canClean
            ) {
                clean(viewModel)
            }
        }
    }

    private func header(_ viewModel: DeveloperCleanupViewModel?) -> some View {
        VStack(spacing: Design.spacingXS) {
            HStack {
                Button {
                    environment.navigation.go(.dashboard)
                } label: {
                    Label("Dashboard", systemImage: "chevron.left")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back to dashboard")
                Spacer()
            }
            .padding(.horizontal, Design.spacingL)
            Text("Developer Cleanup")
                .font(.title2.weight(.bold))
            if let viewModel {
                Text("\(viewModel.foundBytes.formattedByteCount) in caches and build data — nothing is selected automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Caches and build data from Xcode, Node, Python, Homebrew and Docker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, Design.spacingM)
        .accessibilityElement(children: .contain)
    }

    private func toolGroupSection(
        _ viewModel: DeveloperCleanupViewModel,
        group: DeveloperCleanupViewModel.ToolGroup
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.spacingM) {
                TriStateCheckButton(
                    state: group.selection,
                    label: "Select all \(group.name)",
                    action: {
                        viewModel.setGroupSelection(
                            group,
                            isSelected: ResultsViewModel.targetSelection(for: group.selection)
                        )
                    }
                )
                Text(group.name)
                    .font(.headline)
                Spacer(minLength: Design.spacingS)
                Text(group.bytes.formattedByteCount)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .padding(Design.spacingM)
            .accessibilityElement(children: .contain)

            Divider().padding(.leading, Design.spacingM)

            VStack(spacing: 0) {
                ForEach(group.rows) { row in
                    developerRow(viewModel, row: row)
                        .padding(.horizontal, Design.spacingM)
                        .padding(.vertical, 5)
                    Divider().opacity(0.3)
                        .padding(.leading, Design.spacingL)
                }
            }
            .padding(.bottom, Design.spacingS)
        }
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

    private func developerRow(
        _ viewModel: DeveloperCleanupViewModel,
        row: DeveloperCleanupViewModel.Row
    ) -> some View {
        let item = row.item
        return HStack(spacing: Design.spacingM) {
            Toggle(isOn: Binding(
                get: { item.selected },
                set: { viewModel.setSelection($0, itemID: item.id) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("\(item.selected ? "Deselect" : "Select") \(item.name)")
            .accessibilityHint(item.riskLevel == .safe
                ? "Safe to remove, but rebuilds may take longer afterwards."
                : "Review item — off until you select it.")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.isReasonProminent {
                    // Docker rows explain instead of pointing at a path:
                    // the prune note is the primary content.
                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .help(item.path.path)

            RiskBadge(level: item.riskLevel)

            Spacer(minLength: Design.spacingS)

            Button {
                whyItem = item
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Why can I remove this?")
            .accessibilityLabel("About \(item.name)")
            .accessibilityHint("Explains why this item can be removed.")

            Text(item.size.formattedByteCount)
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
    }

    /// Same gate as Results: the confirmation sheet is skipped only when both
    /// confirmation settings are off, and never for destructive selections.
    private func clean(_ viewModel: DeveloperCleanupViewModel) {
        if CleaningFlowPolicy.requiresConfirmation(
            confirmBeforeCleaning: environment.preferences.value.confirmBeforeCleaning,
            askBeforeDeleting: environment.preferences.value.askBeforeDeleting,
            items: viewModel.selectedItems
        ) {
            confirmSheetVisible = true
        } else {
            environment.beginCleaning(AppEnvironment.cleaningRequest(
                for: viewModel.selectedItems,
                scanResultID: viewModel.sourceScanID
            ))
            environment.navigation.go(.cleaning)
        }
    }
}
