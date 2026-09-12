import SwiftUI

/// Spec §9: measured results only — bytes freed, items removed, per-category
/// totals, and new free space when the report carries it.
struct CompletionView: View {
    @Environment(AppEnvironment.self) private var environment

    private var model: CompletionViewModel? {
        environment.lastCleanupReport.map { CompletionViewModel(report: $0, freeSpaceAfter: $0.freeSpaceAfter) }
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                EmptyStateView(
                    systemImage: "checkmark.seal",
                    title: "Nothing to show yet",
                    message: "Run a cleanup and its measured results will appear here."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ model: CompletionViewModel) -> some View {
        ScrollView {
            VStack(spacing: Design.spacingL) {
                if model.removedNothing {
                    removedNothingState(model)
                } else {
                    celebration(model)
                }

                if let newFreeSpaceLine = model.newFreeSpaceLine {
                    Text(newFreeSpaceLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                PrimaryActionButton(
                    title: "Done",
                    hint: "Returns to the dashboard."
                ) {
                    environment.navigation.go(.dashboard)
                }
            }
            .padding(Design.spacingXL)
            .frame(maxWidth: Design.contentWidth)
            .frame(maxWidth: .infinity)
        }
    }

    /// The celebration, shown whenever something was actually freed.
    private func celebration(_ model: CompletionViewModel) -> some View {
        VStack(spacing: Design.spacingL) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(spacing: Design.spacingXS) {
                Text(model.headline)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(model.freedLine)
                    .font(.system(size: 48, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(model.bytesFreed.formattedByteCount) freed")

            VStack(spacing: 2) {
                Text(model.itemsRemovedLine)
                    .font(.body.weight(.medium))
                if let failureLine = model.failureLine {
                    Text(failureLine)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let refusalLine = model.refusalLine {
                    Text(refusalLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .accessibilityElement(children: .combine)

            if !model.categoryRows.isEmpty {
                categoryRows(model)
            }
        }
    }

    /// Free-space refusal or a fully skipped batch: honest and calm, never
    /// an empty celebration with "0 B freed".
    private func removedNothingState(_ model: CompletionViewModel) -> some View {
        VStack(spacing: Design.spacingM) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.nothingRemovedTitle)
                .font(.title3.weight(.semibold))
            Text(model.nothingRemovedMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if model.failureCount > 0, let failureLine = model.failureLine {
                Text(failureLine)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(Design.spacingXL)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
    }

    private func categoryRows(_ model: CompletionViewModel) -> some View {
        VStack(spacing: 0) {
            ForEach(model.categoryRows) { row in
                HStack(spacing: Design.spacingM) {
                    CategoryIcon(category: row.category, size: 24)
                    Text(row.category.displayName)
                        .font(.body)
                    Spacer()
                    Text(row.bytes.formattedByteCount)
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                }
                .padding(.vertical, Design.spacingS)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.category.displayName): \(row.bytes.formattedByteCount) freed")
                Divider().opacity(0.5)
            }
        }
        .padding(.horizontal, Design.spacingM)
        .frame(maxWidth: Design.narrowColumnWidth)
    }
}
