import Foundation

/// What a review screen must expose so ConfirmCleanSheet can run unchanged:
/// Results and Developer Cleanup share one confirmation sheet, so the sheet
/// depends on this seam instead of a concrete view model.
@MainActor
protocol CleaningSelectionProviding: AnyObject {
    var selectedItems: [CleanupItem] { get }
    var selectedBytes: Int64 { get }
    var selectedCount: Int { get }
    var requiresDestructiveConfirmation: Bool { get }
    /// Scan the selection belongs to — carried into the CleaningRequest.
    var sourceScanID: UUID { get }
}
