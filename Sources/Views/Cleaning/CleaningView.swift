import SwiftUI

/// Spec §8: determinate byte progress, current item, per-item ✓/●/○
/// checklist, and the standing warning. Non-dismissable while running —
/// there is no cancel chrome on this screen by design; the executor finishes
/// every started cleanup.
struct CleaningView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: CleaningViewModel?

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .interactiveDismissDisabled(viewModel?.isRunning ?? false)
        .task {
            guard viewModel == nil, let request = environment.takePendingCleaning() else { return }
            let fresh = CleaningViewModel(environment: environment, request: request)
            viewModel = fresh
            fresh.run()
        }
    }

    private func content(_ viewModel: CleaningViewModel) -> some View {
        VStack(spacing: Design.spacingXL) {
            VStack(spacing: Design.spacingS) {
                Text("Cleaning your Mac")
                    .font(.title.weight(.bold))
                Text(currentSummary(viewModel))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, Design.spacingL)
            }
            .accessibilityElement(children: .combine)

            VStack(spacing: Design.spacingS) {
                ProgressView(value: viewModel.fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: Design.narrowColumnWidth)
                    .accessibilityLabel("Cleaning progress")
                Text(viewModel.progressLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            checklist(viewModel)
                .frame(maxWidth: Design.narrowColumnWidth)

            Spacer()

            Label("Don't close Cleanora while cleaning.", systemImage: "lock.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, Design.spacingL)
                .accessibilityElement(children: .combine)
        }
        .padding(.top, Design.spacingXL)
        .onChange(of: viewModel.phase) { _, phase in
            // Cancelled mid-run: nothing further will be removed, go back to
            // the review. (.finished routes to Completion via onFinish.)
            if phase == .cancelled {
                // Items already removed must not linger with stale sizes —
                // Results re-derives its state and banners the difference.
                environment.markResultsStaleAfterCancelledCleanup()
                environment.navigation.go(.results)
            }
        }
    }

    private func currentSummary(_ viewModel: CleaningViewModel) -> String {
        if let item = viewModel.currentItem {
            return "Removing \(item.name)…"
        }
        return viewModel.phase == .finished ? "Finishing up…" : "Preparing…"
    }

    private func checklist(_ viewModel: CleaningViewModel) -> some View {
        VStack(spacing: 6) {
            ForEach(viewModel.checklist, id: \.item.id) { row in
                HStack(spacing: Design.spacingM) {
                    CleaningStateSymbol(row: row)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.item.name)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let refusal = CleaningViewModel.refusalLine(for: row) {
                            Text(refusal)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: Design.spacingS)
                    if let outcome = row.outcome, outcome.bytesFreed > 0 {
                        Text(outcome.bytesFreed.formattedByteCount)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.item.name): \(CleaningViewModel.accessibilitySummary(for: row))")
            }
        }
        .padding(Design.spacingM)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: Design.cornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.cornerRadius)
                .strokeBorder(.quaternary)
        )
    }
}
