import SwiftUI

/// The last stop before deletion (spec §6/U-09): selected items grouped by
/// category with sizes. When anything selected is Trash or flagged
/// destructive, a distinct irreversible warning plus an explicit checkbox is
/// required before the Clean button enables — that flag becomes
/// `destructiveConfirmed` for the executor (invariant I6).
struct ConfirmCleanSheet: View {
    let viewModel: ResultsViewModel
    let onConfirm: (CleaningRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var destructiveConfirmed = false

    private var groups: [(category: ScanCategory, items: [CleanupItem])] {
        ResultsViewModel.confirmGroups(for: viewModel.selectedItems)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Design.spacingXS) {
                Text("Clean selected items")
                    .font(.title3.weight(.bold))
                Text("\(viewModel.selectedBytes.formattedByteCount) — \(ResultsViewModelSummary.countLine(viewModel.selectedCount))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(Design.spacingL)
            .accessibilityElement(children: .combine)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Design.spacingL) {
                    ForEach(groups, id: \.category) { group in
                        groupSection(group)
                    }
                    if viewModel.requiresDestructiveConfirmation {
                        destructiveWarning
                    }
                }
                .padding(Design.spacingL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Closes without deleting anything.")
                Spacer()
                Button("Clean", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.requiresDestructiveConfirmation && !destructiveConfirmed)
                    .accessibilityHint("Removes the listed items. This cannot be undone for Trash contents.")
            }
            .padding(Design.spacingL)
        }
        .frame(width: 460, height: 500)
    }

    private func groupSection(
        _ group: (category: ScanCategory, items: [CleanupItem])
    ) -> some View {
        VStack(alignment: .leading, spacing: Design.spacingS) {
            HStack(spacing: Design.spacingS) {
                CategoryIcon(category: group.category, size: 22)
                Text(group.category.displayName)
                    .font(.headline)
                Spacer()
                Text(group.items.reduce(Int64(0)) { $0 + $1.size }.formattedByteCount)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            VStack(spacing: 4) {
                ForEach(group.items) { item in
                    HStack(spacing: Design.spacingS) {
                        Text(item.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if item.riskLevel == .review {
                            RiskBadge(level: item.riskLevel)
                        }
                        Spacer(minLength: Design.spacingS)
                        Text(item.size.formattedByteCount)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 30)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var destructiveWarning: some View {
        VStack(alignment: .leading, spacing: Design.spacingM) {
            Label("This cannot be undone", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
                .accessibilityHidden(false)
            Text(ScanCategory.trash.whyText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(
                "I understand the Trash will be emptied permanently",
                isOn: $destructiveConfirmed
            )
            .accessibilityHint("Required before Clean is enabled.")
        }
        .padding(Design.spacingM)
        .background(
            Color.red.opacity(0.08),
            in: RoundedRectangle(cornerRadius: Design.cornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.cornerRadius)
                .strokeBorder(Color.red.opacity(0.3))
        )
    }

    private func confirm() {
        let selected = viewModel.selectedItems
        onConfirm(CleaningRequest(
            items: selected,
            confirmed: Set(selected.map(\.id)),
            destructiveConfirmed: destructiveConfirmed,
            selectedBytes: viewModel.selectedBytes,
            scanResultID: viewModel.result.id
        ))
        dismiss()
    }
}
