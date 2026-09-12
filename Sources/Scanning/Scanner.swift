import Foundation

public enum ScannerOutcome: Equatable, Sendable {
    case produced([CleanupItem])
    case skipped(SkipReason)
}

/// One scanner = one category = one independent, cancellation-aware unit of
/// work. Conforming types must be stateless value types; all paths come from
/// the injected environment.
public protocol Scanner: Sendable {
    var category: ScanCategory { get }
    /// Stable key for the progress row (developer scanners emit one row per tool).
    var progressKey: ScannerKey { get }
    var isPhaseOne: Bool { get }

    /// Must poll `Task.isCancelled` at directory boundaries. Progress
    /// callbacks are fire-and-forget; the hub throttles them.
    func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome
}

/// Test double for coordinator + UI work; lets the UI be built against a
/// fixture scanner before real ones land.
public struct MockScanner: Scanner {
    public let category: ScanCategory
    public let progressKey: ScannerKey
    public var isPhaseOne: Bool
    public let result: ScannerOutcome
    public let delay: Duration

    public init(
        category: ScanCategory,
        result: ScannerOutcome,
        delay: Duration = .zero,
        isPhaseOne: Bool = true
    ) {
        self.category = category
        self.result = result
        self.delay = delay
        self.isPhaseOne = isPhaseOne
        self.progressKey = ScannerKey(id: category)
    }

    public func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return result
    }
}
