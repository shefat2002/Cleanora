import SwiftUI

/// The ✓ / ● / ○ state column shared by the scan progress list and the
/// cleaning checklist. Every glyph carries an accessibility label — state is
/// never color-only.
struct ScannerStateSymbol: View {
    let state: ScannerState

    var body: some View {
        symbol
            .frame(width: 20)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var symbol: some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var accessibilityText: String {
        switch state {
        case .pending: return "Waiting"
        case .running: return "Scanning"
        case .completed: return "Completed"
        case .skipped: return "Skipped"
        case .failed: return "Failed"
        }
    }
}

/// Checklist glyph for one item during cleanup.
struct CleaningStateSymbol: View {
    let isCurrent: Bool
    let outcome: ItemOutcome?

    init(row: CleaningViewModel.ChecklistRow) {
        self.isCurrent = row.isCurrent
        self.outcome = row.outcome
    }

    var body: some View {
        symbol
            .frame(width: 20)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var symbol: some View {
        if isCurrent {
            ProgressView().controlSize(.small)
        } else {
            switch outcome?.status {
            case .removed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .partial:
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.orange)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .skipped, .none:
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
    }

    private var accessibilityText: String {
        if isCurrent { return "In progress" }
        switch outcome?.status {
        case .removed: return "Removed"
        case .partial: return "Partially removed"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        case .none: return "Waiting"
        }
    }
}
