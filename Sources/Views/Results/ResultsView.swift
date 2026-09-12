import SwiftUI

/// Spec §6: scan results with per-category disclosure, app grouping, tri-state
/// selection and a sticky summary bar. Everything the user sees is real scan
/// output; review items start unselected and say so.
struct ResultsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: ResultsViewModel?
    @State private var collapsedCategories: Set<ScanCategory> = []
    @State private var whyCategory: ScanCategory?
    @State private var whyItem: CleanupItem?
    @State private var confirmSheetVisible = false

    var body: some View {
        Group {
            if let viewModel {
                if viewModel.isEmpty {
                    EmptyStateView(
                        systemImage: "sparkles",
                        title: "Nothing to clean",
                        message: "The scan didn't find any cleanable files. Your Mac looks tidy.",
                        actionTitle: "Back to Dashboard"
                    ) {
                        environment.navigation.go(.dashboard)
                    }
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
            let fresh = ResultsViewModel(result: result)
            viewModel = fresh
        }
        .sheet(item: $whyCategory) { category in
            WhyInfoSheet(category: category, item: whyItem)
        }
        .sheet(isPresented: $confirmSheetVisible) {
            if let viewModel {
                ConfirmCleanSheet(viewModel: viewModel) { request in
                    environment.beginCleaning(request)
                    environment.navigation.go(.cleaning)
                }
            }
        }
    }

    private func content(_ viewModel: ResultsViewModel) -> some View {
        VStack(spacing: 0) {
            header(viewModel)
            Divider()
            ScrollView {
                LazyVStack(spacing: Design.spacingM) {
                    ForEach(viewModel.sections) { section in
                        CategoryDisclosureSection(
                            section: section,
                            collapsedCategories: Binding(
                                get: { collapsedCategories },
                                set: { collapsedCategories = $0 }
                            ),
                            onToggleCategory: { isSelected in
                                viewModel.setCategorySelection(section.category, isSelected: isSelected)
                            },
                            onToggleGroup: { group, isSelected in
                                viewModel.setSelection(isSelected, itemIDs: group.itemIDs)
                            },
                            onToggleItem: { itemID, isSelected in
                                viewModel.setSelection(isSelected, itemID: itemID)
                            },
                            onWhyCategory: {
                                whyItem = nil
                                whyCategory = section.category
                            },
                            onWhyItem: { item in
                                whyItem = item
                                whyCategory = item.category
                            }
                        )
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
                confirmSheetVisible = true
            }
        }
    }

    private func header(_ viewModel: ResultsViewModel) -> some View {
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
                .accessibilityHint("Leaves the results; a new scan replaces them.")
                Spacer()
            }
            .padding(.horizontal, Design.spacingL)
            Text("Scan Complete")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("\(viewModel.foundBytes.formattedByteCount) can potentially be cleaned")
                .font(.title2.weight(.bold))
            if viewModel.reviewBytes > 0 {
                Text("\(viewModel.reviewBytes.formattedByteCount) is marked “Review” and stays unselected until you choose it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.bottom, Design.spacingM)
        .accessibilityElement(children: .contain)
    }
}
