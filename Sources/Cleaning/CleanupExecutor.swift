import Foundation

// MARK: - FROZEN CONTRACT (cleanup agent implements behind these signatures)

public struct CleanupProgress: Sendable {
    public let currentItem: CleanupItem?
    public let outcomes: [ItemOutcome]
    public let bytesFreedSoFar: Int64

    public init(currentItem: CleanupItem?, outcomes: [ItemOutcome], bytesFreedSoFar: Int64) {
        self.currentItem = currentItem
        self.outcomes = outcomes
        self.bytesFreedSoFar = bytesFreedSoFar
    }
}

public enum CleanupEvent: Sendable {
    case progress(CleanupProgress)
    case finished(CleanupReport)
}

/// Sequential, safety-gated deletion. Per item: SafetyPolicy.validate →
/// log attempt (I9) → delete via DeletionMethodExecutor → re-stat for measured
/// bytesFreed → log result. One failure never aborts the batch (I11);
/// cancellation lands between items (I12).
public struct CleanupExecutor: Sendable {
    public init(
        policy: SafetyPolicy,
        logger: CleanupLogger,
        environment: ScanEnvironment,
        diskInfo: DiskInfoProvider
    ) {}

    public func run(
        items: [CleanupItem],
        confirmed: Set<UUID>,
        destructiveConfirmed: Bool
    ) -> AsyncStream<CleanupEvent> {
        AsyncStream { continuation in
            continuation.yield(.finished(CleanupReport(
                startedAt: Date(), finishedAt: Date(), outcomes: [],
                freeSpaceBefore: nil, freeSpaceAfter: nil, scanResultID: nil
            )))
            continuation.finish()
        }
    }
}
