import SwiftUI

/// Spec §5: live per-scanner rows (✓ / ● / ○), live bytes, overall progress,
/// and a working Cancel. Failure and cancellation render as calm states with
/// a retry — never as errors shouting.
struct ScanProgressView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: ScanViewModel?

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
        .task {
            if let viewModel {
                viewModel.start() // no-op unless idle
            } else {
                let fresh = ScanViewModel(environment: environment)
                viewModel = fresh
                fresh.start()
            }
        }
    }

    @ViewBuilder
    private func content(_ viewModel: ScanViewModel) -> some View {
        switch viewModel.phase {
        case .failed(let message):
            VStack(spacing: Design.spacingL) {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "Scan failed",
                    message: message.isEmpty
                        ? "Something went wrong while scanning. Nothing was changed."
                        : message,
                    actionTitle: "Try Again"
                ) {
                    viewModel.reset()
                    viewModel.start()
                }
                Button("Back to Dashboard") {
                    environment.navigation.go(.dashboard)
                }
                .accessibilityHint("Returns to the dashboard without scanning.")
            }
        case .cancelled:
            VStack(spacing: Design.spacingL) {
                EmptyStateView(
                    systemImage: "minus.circle",
                    title: "Scan cancelled",
                    message: "The scan stopped early, so results would be incomplete. Nothing was changed.",
                    actionTitle: "Scan Again"
                ) {
                    viewModel.reset()
                    viewModel.start()
                }
                Button("Back to Dashboard") {
                    environment.navigation.go(.dashboard)
                }
            }
        case .idle:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .running, .finished:
            scanningContent(viewModel)
        }
    }

    private func scanningContent(_ viewModel: ScanViewModel) -> some View {
        ScrollView {
            VStack(spacing: Design.spacingXL) {
                VStack(spacing: Design.spacingM) {
                    Text("Scanning your Mac…")
                        .font(.title.weight(.semibold))
                    VStack(spacing: Design.spacingS) {
                        ProgressView(value: viewModel.overallFraction)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: Design.narrowColumnWidth)
                        HStack {
                            Text("\(viewModel.discoveredBytes.formattedByteCount) found so far")
                            Spacer()
                            Text("\(completedCount(viewModel)) of \(viewModel.keys.count) checks done")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(maxWidth: Design.narrowColumnWidth)
                    }
                    if let permissionMessage = ScanViewModel.permissionDeniedMessage(in: viewModel.progress) {
                        PermissionBanner {
                            environment.openFullDiskAccessSettings()
                        }
                        .frame(maxWidth: Design.narrowColumnWidth)
                        .accessibilityLabel(permissionMessage)
                    }
                }
                .accessibilityElement(children: .contain)

                VStack(spacing: 0) {
                    ForEach(viewModel.rows, id: \.key) { row in
                        rowView(row)
                        Divider().opacity(0.5)
                    }
                }
                .frame(maxWidth: Design.narrowColumnWidth)
                .padding(.horizontal, Design.spacingM)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: Design.cornerRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Design.cornerRadius)
                        .strokeBorder(.quaternary)
                )

                Button("Cancel", action: viewModel.cancel)
                    .accessibilityLabel("Cancel scan")
                    .accessibilityHint("Stops the scan. Nothing is deleted during a scan.")
            }
            .padding(Design.spacingXL)
            .frame(maxWidth: Design.contentWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private func completedCount(_ viewModel: ScanViewModel) -> Int {
        viewModel.progress.completedCount
    }

    private func rowView(_ row: ScanViewModel.Row) -> some View {
        HStack(spacing: Design.spacingM) {
            ScannerStateSymbol(state: row.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.key.label)
                    .font(.body)
                if let detail = ScanViewModel.detailText(for: row.state) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, Design.spacingS)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.key.label): \(rowAccessibilityText(row.state))")
    }

    private func rowAccessibilityText(_ state: ScannerState) -> String {
        switch state {
        case .pending: return "waiting"
        case .running: return "scanning"
        case .completed: return "completed"
        case .skipped: return "skipped"
        case .failed: return "failed"
        }
    }
}
