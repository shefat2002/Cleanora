import Foundation

/// A fully-specified cleanup, produced by ConfirmCleanSheet and consumed by
/// CleaningView. Carries everything the executor needs and nothing about UI.
/// `confirmed` is the explicit set of item IDs the user confirmed in the
/// sheet (SafetyPolicy invariant I5); `destructiveConfirmed` is the separate
/// irreversible-step acknowledgment required by I6.
struct CleaningRequest: Sendable {
    let items: [CleanupItem]
    let confirmed: Set<UUID>
    let destructiveConfirmed: Bool
    /// Denominator for the determinate progress bar.
    let selectedBytes: Int64
    let scanResultID: UUID?
}
