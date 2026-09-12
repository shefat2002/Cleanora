import Foundation
import Observation

/// Drives one cleanup: consumes the executor's frozen stream, keeps the
/// determinate byte progress, the per-item checklist state, and hands the
/// measured report to the app (which persists history and routes to
/// Completion).
@MainActor
@Observable
final class CleaningViewModel {
    enum Phase: Equatable {
        case idle
        case running
        case finished
        case cancelled
    }

    struct ChecklistRow: Equatable {
        let item: CleanupItem
        /// nil until the executor has reported an outcome for this item.
        let outcome: ItemOutcome?
        let isCurrent: Bool
    }

    private(set) var phase: Phase = .idle
    private(set) var currentItem: CleanupItem?
    private(set) var bytesFreedSoFar: Int64 = 0
    private(set) var report: CleanupReport?

    /// Selected items in execution order — the checklist backbone.
    let items: [CleanupItem]
    /// Progress denominator, from the confirmation sheet.
    let selectedBytes: Int64

    var isRunning: Bool { phase == .running }

    var fraction: Double {
        guard selectedBytes > 0 else { return 0 }
        return min(1, Double(bytesFreedSoFar) / Double(selectedBytes))
    }

    /// "5.4 GB / 6.9 GB"
    var progressLine: String {
        "\(bytesFreedSoFar.formattedByteCount) / \(selectedBytes.formattedByteCount)"
    }

    private var outcomes: [UUID: ItemOutcome] = [:]
    private var outcomeOrder: [UUID] = []
    private let request: CleaningRequest
    private let makeStream: @MainActor (CleaningRequest) -> AsyncStream<CleanupEvent>
    private let onFinish: @MainActor (CleanupReport) -> Void
    private var task: Task<Void, Never>?

    init(
        request: CleaningRequest,
        makeStream: @escaping @MainActor (CleaningRequest) -> AsyncStream<CleanupEvent>,
        onFinish: @escaping @MainActor (CleanupReport) -> Void = { _ in }
    ) {
        self.items = request.items
        self.selectedBytes = request.selectedBytes
        self.request = request
        self.makeStream = makeStream
        self.onFinish = onFinish
    }

    convenience init(environment: AppEnvironment, request: CleaningRequest) {
        self.init(
            request: request,
            makeStream: { request in
                environment.cleanupExecutor().run(
                    items: request.items,
                    confirmed: request.confirmed,
                    destructiveConfirmed: request.destructiveConfirmed
                )
            },
            onFinish: { report in
                environment.finishCleanup(report)
                environment.navigation.go(.completion)
            }
        )
    }

    func run() {
        guard phase == .idle else { return }
        phase = .running
        task = Task { [weak self] in
            guard let self else { return }
            for await event in self.makeStream(self.request) {
                self.apply(event)
            }
            if self.phase == .running {
                self.phase = .cancelled
            }
        }
    }

    /// Cancels between items (invariant I12 lives in the executor). The view
    /// navigates back to Results when it observes `.cancelled`.
    func cancel() {
        task?.cancel()
    }

    private func apply(_ event: CleanupEvent) {
        switch event {
        case .progress(let progress):
            currentItem = progress.currentItem
            bytesFreedSoFar = progress.bytesFreedSoFar
            // Tolerant merge: the stream may send cumulative or incremental
            // outcome lists; storing by ID keeps either shape correct.
            for outcome in progress.outcomes where outcomes[outcome.id] == nil {
                outcomeOrder.append(outcome.id)
            }
            for outcome in progress.outcomes {
                outcomes[outcome.id] = outcome
            }
        case .finished(let finishedReport):
            currentItem = nil
            report = finishedReport
            phase = .finished
            onFinish(finishedReport)
        }
    }

    var checklist: [ChecklistRow] {
        items.map { ChecklistRow(item: $0, outcome: outcomes[$0.id], isCurrent: currentItem?.id == $0.id) }
    }

    // MARK: - Pure presentation logic

    nonisolated static func accessibilitySummary(for row: ChecklistRow) -> String {
        if row.isCurrent { return "In progress" }
        guard let outcome = row.outcome else { return "Waiting" }
        switch outcome.status {
        case .removed:
            return "Removed, \(outcome.bytesFreed.formattedByteCount) freed"
        case .partial:
            return "Partially removed"
        case .failed:
            if let message = outcome.message, !message.isEmpty {
                return "Failed: \(message)"
            }
            return "Failed"
        case .skipped:
            return "Skipped"
        }
    }
}
