import Foundation

// MARK: - FROZEN CONTRACT (cleanup agent implements behind these signatures)

public enum LogEntry: Equatable, Codable, Sendable {
    case attempt(itemID: UUID, name: String, path: String, date: Date)
    case result(itemID: UUID, status: ItemOutcome.Status, bytesFreed: Int64, date: Date)
}

/// Write-ahead cleanup logger (invariant I9): the attempt is on disk BEFORE
/// the destructive call, the result after. Appends must fsync — an atomic
/// write alone can lose the journal on power loss while deletions persist.
public final class CleanupLogger: @unchecked Sendable {
    public init(appDirs: AppDirectories) {}

    public func appendAttempt(_ item: CleanupItem) {}
    public func appendResult(_ outcome: ItemOutcome) {}
    public func readCurrentLog() -> [LogEntry] { [] }
    public var currentLogURL: URL? { nil }
}
