import Foundation

// MARK: - FROZEN CONTRACT (cleanup agent implements behind these signatures)

/// Persists the last scan (Dashboard) and cleanup history (History screen).
/// Versioned JSON via JSONFileStore; corrupt files recover to empty.
public struct ScanHistoryStore: Sendable {
    /// `directory` is Cleanora's Application Support directory.
    public init(directory: URL) {}

    public func saveLastScan(_ result: ScanResult) {}
    public func lastScan() -> ScanResult? { nil }

    public func appendHistory(_ entry: CleanupHistoryEntry) {}
    public func history(limit: Int = 100) -> [CleanupHistoryEntry] { [] }
}
