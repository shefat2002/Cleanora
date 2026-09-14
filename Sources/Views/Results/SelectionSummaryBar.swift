import SwiftUI

/// Sticky footer of the Results screen: instant totals plus the single
/// primary action. "Clean Now" enables only when something is selected.
struct SelectionSummaryBar: View {
    /// Action copy; the uninstaller screen says "Uninstall", the duplicate
    /// finder "Move to Trash", everything else keeps "Clean Now".
    var title: String = "Clean Now"
    let selectedBytes: Int64
    let selectedCount: Int
    let canClean: Bool
    let onClean: () -> Void

    var body: some View {
        HStack(spacing: Design.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectedBytes.formattedByteCount) selected")
                    .font(.headline)
                    .monospacedDigit()
                Text(ResultsViewModelSummary.countLine(selectedCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(selectedBytes.formattedByteCount) selected, \(ResultsViewModelSummary.countLine(selectedCount))")

            Spacer(minLength: Design.spacingS)

            PrimaryActionButton(
                title: title,
                systemImage: "sparkles",
                hint: canClean
                    ? "Shows what will be removed before anything is deleted."
                    : "Select at least one item to clean.",
                isEnabled: canClean,
                action: onClean
            )
        }
        .padding(.horizontal, Design.spacingL)
        .padding(.vertical, Design.spacingM)
    }
}

/// Shared pluralization so the footer and the confirmation sheet agree.
enum ResultsViewModelSummary {
    static func countLine(_ count: Int) -> String {
        switch count {
        case 0: return "no items"
        case 1: return "1 item"
        default: return "\(count) items"
        }
    }
}
