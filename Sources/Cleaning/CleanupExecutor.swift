import Foundation
import os

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
/// measured size before → durable attempt record (I9) → DeletionMethodExecutor
/// → measured size after → result record. One failure never aborts the batch
/// (I11); cancellation lands between items (I12).
public struct CleanupExecutor: Sendable {
    private static let log = Logger(subsystem: "com.cleanora.app", category: "cleanup")

    /// Safety floor: refuse the whole batch when free space is below the
    /// larger of this and the batch's estimated bytes (decimal GB, matching
    /// ByteCountFormatting).
    static let minimumFreeSpaceBytes: Int64 = 2_000_000_000

    private let policy: SafetyPolicy
    private let logger: CleanupLogger
    private let environment: ScanEnvironment
    private let deletionExecutor: DeletionMethodExecutor
    private let probe = ContentSizeProbe()
    private let freeSpace: @Sendable () -> Int64?

    public init(
        policy: SafetyPolicy,
        logger: CleanupLogger,
        environment: ScanEnvironment,
        diskInfo: DiskInfoProvider
    ) {
        self.policy = policy
        self.logger = logger
        self.environment = environment
        self.deletionExecutor = DeletionMethodExecutor()
        self.freeSpace = { diskInfo.availableBytes() }
    }

    /// Internal seam: deletion executor and free-space readings injected
    /// directly so tests can stage trash semantics and disk state without
    /// touching the real Trash or real volumes.
    init(
        policy: SafetyPolicy,
        logger: CleanupLogger,
        environment: ScanEnvironment,
        deletion: DeletionMethodExecutor,
        freeSpace: @escaping @Sendable () -> Int64?
    ) {
        self.policy = policy
        self.logger = logger
        self.environment = environment
        self.deletionExecutor = deletion
        self.freeSpace = freeSpace
    }

    public func run(
        items: [CleanupItem],
        confirmed: Set<UUID>,
        destructiveConfirmed: Bool
    ) -> AsyncStream<CleanupEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let cancelled = OSAllocatedUnfairLock(initialState: false)
            // The consumer went away (window closed or consuming task
            // cancelled): stop starting new deletions at the next item
            // boundary — I12.
            continuation.onTermination = { _ in
                cancelled.withLock { $0 = true }
            }
            // All emission happens from this single task; the loop is
            // strictly sequential.
            Task {
                await self.execute(
                    items: items,
                    confirmed: confirmed,
                    destructiveConfirmed: destructiveConfirmed,
                    continuation: continuation,
                    cancelled: cancelled
                )
            }
        }
    }

    private func execute(
        items: [CleanupItem],
        confirmed: Set<UUID>,
        destructiveConfirmed: Bool,
        continuation: AsyncStream<CleanupEvent>.Continuation,
        cancelled: OSAllocatedUnfairLock<Bool>
    ) async {
        let startedAt = Date()
        let freeBefore = freeSpace()
        var outcomes: [ItemOutcome] = []

        // Free-space floor: never delete into a full disk.
        let selectedBytes = items.reduce(Int64(0)) { $0 + $1.size }
        let requiredBytes = max(Self.minimumFreeSpaceBytes, selectedBytes)
        if let available = freeBefore, available < requiredBytes {
            let message = "Refused: only \(available.formattedByteCount) of free space available, " +
                "\(requiredBytes.formattedByteCount) required (safety floor). Nothing was deleted."
            outcomes = items.map { item in
                ItemOutcome(
                    itemID: item.id, name: item.name, category: item.category,
                    path: item.path.path, status: .skipped, bytesFreed: 0, message: message
                )
            }
            Self.log.notice("cleanup refused: \(available) bytes free, \(requiredBytes) required")
            emitFinished(
                continuation: continuation, startedAt: startedAt,
                outcomes: outcomes, before: freeBefore
            )
            return
        }

        // Trash empties FIRST: any recoverable item moved into ~/.Trash
        // later in the same batch must not be destroyed by this run's
        // trash-emptying (reviewer finding: recovery promise would be
        // silently voided otherwise). Stable sort preserves the rest.
        let orderedItems = items.enumerated().sorted { lhs, rhs in
            let lhsTrash = lhs.element.category == .trash
            let rhsTrash = rhs.element.category == .trash
            if lhsTrash != rhsTrash { return lhsTrash }
            return lhs.offset < rhs.offset
        }.map(\.element)

        for item in orderedItems {
            // I12: cancellation is checked between items, so everything
            // after the check stays untouched.
            if cancelled.withLock({ $0 }) || Task.isCancelled {
                outcomes.append(
                    ItemOutcome(
                        itemID: item.id, name: item.name, category: item.category,
                        path: item.path.path, status: .skipped, bytesFreed: 0,
                        message: "Cancelled before deletion"
                    )
                )
                continue
            }
            continuation.yield(.progress(CleanupProgress(
                currentItem: item,
                outcomes: outcomes,
                bytesFreedSoFar: outcomes.reduce(0) { $0 + $1.bytesFreed }
            )))
            outcomes.append(
                process(item, confirmed: confirmed, destructiveConfirmed: destructiveConfirmed)
            )
        }

        emitFinished(
            continuation: continuation, startedAt: startedAt,
            outcomes: outcomes, before: freeBefore
        )
    }

    private func process(
        _ item: CleanupItem,
        confirmed: Set<UUID>,
        destructiveConfirmed: Bool
    ) -> ItemOutcome {
        // The gate: SafetyPolicy is the ONLY authority. Validate immediately
        // before deletion — selection/confirmation is re-proven per item, in
        // case anything changed since the batch was assembled (I2–I6, I10).
        do {
            try policy.validate(
                item, confirmed: confirmed, destructiveConfirmed: destructiveConfirmed
            )
        } catch let violation as SafetyPolicy.Violation {
            return refusal(item: item, reason: Self.refusalMessage(violation))
        } catch {
            return refusal(item: item, reason: "Refused: \(error.localizedDescription)")
        }

        let sizeBefore = probe.logicalBytes(at: item.path) ?? 0
        // I9 with teeth: if the WAL write fails, the item is left untouched —
        // a deletion without a durable attempt record is unrecoverable.
        guard logger.attemptRecord(item) else {
            Self.log.error("cleanup: WAL not writable; refusing to delete \(item.path.path, privacy: .public)")
            return ItemOutcome(
                itemID: item.id, name: item.name, category: item.category,
                path: item.path.path, status: .failed, bytesFreed: 0,
                message: "Cleanup log is not writable; item left untouched"
            )
        }

        let deletion = deletionExecutor.delete(item, home: environment.home)
        let sizeAfter = probe.logicalBytes(at: item.path) ?? 0

        let status: ItemOutcome.Status
        switch deletion.kind {
        case .removed: status = .removed
        case .partial: status = .partial
        case .failed: status = .failed
        case .alreadyGone: status = .skipped
        }

        // Measured, never estimated: before − after re-stat.
        let outcome = ItemOutcome(
            itemID: item.id, name: item.name, category: item.category,
            path: item.path.path, status: status,
            bytesFreed: max(0, sizeBefore - sizeAfter),
            message: deletion.message
        )
        logger.appendResult(outcome)
        return outcome
    }

    private func refusal(item: CleanupItem, reason: String) -> ItemOutcome {
        ItemOutcome(
            itemID: item.id, name: item.name, category: item.category,
            path: item.path.path, status: .skipped, bytesFreed: 0, message: reason
        )
    }

    static func refusalMessage(_ violation: SafetyPolicy.Violation) -> String {
        switch violation {
        case .outsideAllowedRoots(let path):
            return "Refused: path is outside the allowed cleanup roots (\(path))"
        case .blockedPath(let path):
            return "Refused: protected path (\(path))"
        case .blockedFragment(let fragment):
            return "Refused: protected content (\(fragment))"
        case .neverRiskNotAllowed(let path):
            return "Refused: item is not eligible for deletion (\(path))"
        case .itemNotSelected(let path):
            return "Refused: item was not selected (\(path))"
        case .missingConfirmation(let path):
            return "Refused: no user confirmation for (\(path))"
        case .destructiveWithoutExplicitConfirm(let path):
            return "Refused: destructive cleanup needs explicit confirmation (\(path))"
        case .symlinkLeafNotAllowed(let path):
            return "Refused: unverifiable symlink; only the recoverable trash method is allowed (\(path))"
        }
    }

    private func emitFinished(
        continuation: AsyncStream<CleanupEvent>.Continuation,
        startedAt: Date,
        outcomes: [ItemOutcome],
        before: Int64?
    ) {
        continuation.yield(.finished(CleanupReport(
            startedAt: startedAt,
            finishedAt: Date(),
            outcomes: outcomes,
            freeSpaceBefore: before,
            freeSpaceAfter: freeSpace(),
            scanResultID: nil
        )))
        continuation.finish()
    }
}
