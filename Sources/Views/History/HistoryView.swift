import SwiftUI

/// Spec §10: day-grouped cleanup history with a detail pane. Read-only;
/// entries come from ScanHistoryStore.
struct HistoryView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: HistoryViewModel?
    @State private var selectedEntry: CleanupHistoryEntry?

    var body: some View {
        Group {
            if let viewModel {
                if viewModel.groups.isEmpty {
                    VStack(spacing: 0) {
                        header
                        Divider()
                        EmptyStateView(
                            systemImage: "clock.arrow.circlepath",
                            title: "No cleanups yet",
                            message: "After your first cleanup, its results are listed here."
                        )
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
            if viewModel == nil {
                viewModel = HistoryViewModel(environment: environment)
            }
            viewModel?.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: Design.spacingM) {
            Button {
                environment.navigation.go(.dashboard)
            } label: {
                Label("Dashboard", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Back to dashboard")
            Text("Cleanup History")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, Design.spacingL)
        .padding(.vertical, Design.spacingM)
    }

    private func content(_ viewModel: HistoryViewModel) -> some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list(viewModel)
                    .frame(width: 280)
                Divider()
                detail(viewModel)
            }
        }
    }

    private func list(_ viewModel: HistoryViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.spacingL) {
                ForEach(viewModel.groups) { group in
                    VStack(alignment: .leading, spacing: Design.spacingXS) {
                        Text(group.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Design.spacingM)
                        ForEach(group.entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
            .padding(Design.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func entryRow(_ entry: CleanupHistoryEntry) -> some View {
        let isSelected = selectedEntry?.id == entry.id
        return Button {
            selectedEntry = entry
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DateFormatting.timestampLine(
                        for: entry.date,
                        now: Date()
                    ))
                    .font(.callout)
                    Text(entry.bytesFreed.formattedByteCount + " freed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Design.spacingM)
            .padding(.vertical, Design.spacingS)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: Design.cornerRadius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cleanup at \(entry.bytesFreed.formattedByteCount) freed, \(entry.itemsRemoved) items removed")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func detail(_ viewModel: HistoryViewModel) -> some View {
        if let entry = selectedEntry ?? viewModel.groups.first?.entries.first {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.spacingL) {
                    VStack(alignment: .leading, spacing: Design.spacingXS) {
                        Text(DateFormatting.longDateTime(entry.date))
                            .font(.title3.weight(.semibold))
                        Text("\(entry.bytesFreed.formattedByteCount) freed")
                            .font(.title.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    HStack(spacing: Design.spacingM) {
                        StatTile(
                            value: entry.bytesFreed.formattedByteCount,
                            caption: "Space freed",
                            systemImage: "arrow.down.to.line.compact"
                        )
                        StatTile(
                            value: "\(entry.itemsRemoved)",
                            caption: "Items removed",
                            systemImage: "tray.full"
                        )
                    }
                    if !entry.categoryTotals.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(entry.categoryTotals, id: \.category) { total in
                                HStack(spacing: Design.spacingM) {
                                    CategoryIcon(category: total.category, size: 22)
                                    Text(total.category.displayName)
                                        .font(.body)
                                    Spacer()
                                    Text(total.bytes.formattedByteCount)
                                        .font(.body.weight(.medium))
                                        .monospacedDigit()
                                }
                                .padding(.vertical, Design.spacingS)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(total.category.displayName): \(total.bytes.formattedByteCount)")
                                Divider().opacity(0.5)
                            }
                        }
                    }
                }
                .padding(Design.spacingL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyStateView(
                systemImage: "doc.text.magnifyingglass",
                title: "Select an entry",
                message: "Choose a cleanup on the left to see what was removed."
            )
        }
    }
}
