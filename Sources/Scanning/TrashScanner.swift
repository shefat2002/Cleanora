import Foundation

/// C-06 — the Trash as exactly one item, measured recursively.
///
/// The whole `.Trash` is a single `.removeContents` item with
/// `.destructive` confirmation: emptying it is irreversible, which the
/// reason states explicitly and the cleanup gate enforces (I6).
public struct TrashScanner: Scanner {
    public let category: ScanCategory = .trash
    public let progressKey: ScannerKey
    public let isPhaseOne: Bool = true

    public init() {
        self.progressKey = ScannerKey(id: .trash)
    }

    public func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome {
        let trash = environment.trash
        if let reason = ScannerGuards.skipReason(root: trash, environment: environment) {
            return .skipped(reason)
        }
        guard !Task.isCancelled else { return .produced([]) }
        onProgress(progressKey, .running(bytesScanned: 0, itemsFound: 0))

        let measurement = await DirectorySizeCalculator().measure(at: trash)
        guard measurement.fileCount > 0 else { return .produced([]) } // nothing to empty

        onProgress(progressKey, .running(
            bytesScanned: measurement.bytes, itemsFound: 1
        ))
        return .produced([CleanupItem(
            name: "Trash",
            appName: nil,
            category: .trash,
            path: trash,
            size: measurement.bytes,
            fileCount: measurement.fileCount,
            riskLevel: .safe,
            reason: "These items are already deleted; emptying the Trash is irreversible and cannot be undone.",
            deletionMethod: .removeContents,
            confirmationLevel: .destructive
        )])
    }
}
