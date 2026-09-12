import SwiftUI

/// One expandable category card: tri-state header, app-name groups with the
/// "Other" rollup, or a flat item list when grouping doesn't apply. Groups
/// and the category itself start expanded — transparency by default.
struct CategoryDisclosureSection: View {
    let section: ResultsViewModel.Section
    /// Categories the user collapsed; absence means expanded.
    @Binding var collapsedCategories: Set<ScanCategory>
    let onToggleCategory: (Bool) -> Void
    let onToggleGroup: (ResultsViewModel.AppGroup, Bool) -> Void
    let onToggleItem: (UUID, Bool) -> Void
    let onWhyCategory: () -> Void
    let onWhyItem: (CleanupItem) -> Void

    /// Groups the user collapsed; absence means expanded.
    @State private var collapsedGroups: Set<String> = []

    private var isExpanded: Bool {
        !collapsedCategories.contains(section.category)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider().padding(.leading, Design.spacingM)
                content
            }
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

    private var header: some View {
        HStack(spacing: Design.spacingM) {
            TriStateCheckButton(
                state: section.selection,
                label: "Select all \(section.category.displayName)",
                action: {
                    onToggleCategory(
                        ResultsViewModel.targetSelection(for: section.selection)
                    )
                }
            )
            CategoryIcon(category: section.category, size: 26)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    toggleExpanded()
                }
            } label: {
                HStack(spacing: Design.spacingS) {
                    Text(section.category.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if section.isReviewOnly {
                        RiskBadge(level: .review)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(section.category.displayName)")
            .accessibilityHint("Shows or hides the items in this category.")

            Spacer(minLength: Design.spacingS)

            Button(action: onWhyCategory) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Why can I remove this?")
            .accessibilityLabel("About \(section.category.displayName)")
            .accessibilityHint("Explains why this category can be cleaned.")

            Text(section.bytes.formattedByteCount)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(Design.spacingM)
    }

    @ViewBuilder
    private var content: some View {
        if section.groups.isEmpty {
            VStack(spacing: 0) {
                ForEach(section.items) { item in
                    CleanupItemRow(
                        item: item,
                        onToggle: { onToggleItem(item.id, $0) },
                        onWhy: { onWhyItem(item) }
                    )
                    .padding(.leading, Design.spacingL)
                }
            }
            .padding(.bottom, Design.spacingS)
        } else {
            VStack(spacing: 0) {
                ForEach(section.groups) { group in
                    groupView(group)
                }
            }
            .padding(.bottom, Design.spacingS)
        }
    }

    private func groupView(_ group: ResultsViewModel.AppGroup) -> some View {
        let isGroupExpanded = !collapsedGroups.contains(group.id)
        return VStack(spacing: 0) {
            HStack(spacing: Design.spacingS) {
                TriStateCheckButton(
                    state: ResultsViewModel.selectionState(of: group.items),
                    label: "Select all \(group.name)",
                    action: {
                        onToggleGroup(
                            group,
                            ResultsViewModel.targetSelection(
                                for: ResultsViewModel.selectionState(of: group.items)
                            )
                        )
                    }
                )
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        toggleGroup(group.id)
                    }
                } label: {
                    HStack(spacing: Design.spacingXS) {
                        Text(group.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isGroupExpanded ? 90 : 0))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isGroupExpanded ? "Collapse" : "Expand") \(group.name)")
                Spacer(minLength: Design.spacingS)
                Text(group.bytes.formattedByteCount)
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .padding(.horizontal, Design.spacingL)
            .padding(.vertical, Design.spacingS)
            .accessibilityElement(children: .contain)

            if isGroupExpanded {
                VStack(spacing: 0) {
                    ForEach(group.items) { item in
                        CleanupItemRow(
                            item: item,
                            onToggle: { onToggleItem(item.id, $0) },
                            onWhy: { onWhyItem(item) }
                        )
                        .padding(.leading, Design.spacingL * 2)
                    }
                }
            }
            Divider().opacity(0.3)
        }
        .padding(.trailing, Design.spacingM)
    }

    private func toggleExpanded() {
        if isExpanded {
            collapsedCategories.insert(section.category)
        } else {
            collapsedCategories.remove(section.category)
        }
    }

    private func toggleGroup(_ id: String) {
        if collapsedGroups.contains(id) {
            collapsedGroups.remove(id)
        } else {
            collapsedGroups.insert(id)
        }
    }
}
