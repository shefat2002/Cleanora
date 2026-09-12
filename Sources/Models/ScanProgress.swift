import Foundation

/// Identity of one progress row. `label` lets a category fan out into
/// per-tool rows without changing any UI code.
public struct ScannerKey: Hashable, Codable, Sendable, Identifiable {
    public let id: ScanCategory
    public let label: String

    public init(id: ScanCategory, label: String? = nil) {
        self.id = id
        self.label = label ?? id.displayName
    }
}

public enum ScannerState: Equatable, Sendable {
    case pending
    case running(bytesScanned: Int64, itemsFound: Int)
    case completed(totalBytes: Int64, itemCount: Int)
    case skipped(SkipReason)
    case failed(String)
}

public enum SkipReason: Equatable, Codable, Sendable {
    case disabledByUser
    case pathNotFound(String)
    case permissionDenied(String)
    case toolNotInstalled(String)
    case tooLargeToScan
}

public struct ScanProgress: Equatable, Sendable {
    public var states: [ScannerKey: ScannerState]

    public init(states: [ScannerKey: ScannerState] = [:]) {
        self.states = states
    }

    public func state(for key: ScannerKey) -> ScannerState {
        states[key] ?? .pending
    }

    public var completedCount: Int {
        states.values.filter {
            switch $0 {
            case .completed, .skipped, .failed: return true
            default: return false
            }
        }.count
    }

    /// Denominator is the enabled scanner set, so a disabled scanner never
    /// stalls the bar.
    public func overallFraction(totalScanners: Int) -> Double {
        guard totalScanners > 0 else { return 0 }
        return min(1, Double(completedCount) / Double(totalScanners))
    }

    public var discoveredBytes: Int64 {
        states.values.reduce(0) { partial, state in
            switch state {
            case .running(let bytes, _): return partial + bytes
            case .completed(let total, _): return partial + total
            default: return partial
            }
        }
    }
}
