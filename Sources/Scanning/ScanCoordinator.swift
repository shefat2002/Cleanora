import Foundation

// MARK: - FROZEN CONTRACT (agents implement behind these signatures)

public enum ScanUpdate: Sendable {
    case progress(ScanProgress)
    case finished(ScanResult)
    case failed(String)
}

/// Runs enabled scanners concurrently (TaskGroup), emits throttled progress,
/// produces one finished ScanResult. Consuming the stream is the cancellation
/// handle: breaking the `for await` cancels every scanner via onTermination.
public struct ScanCoordinator: Sendable {
    public let scanners: [any Scanner]
    public let environment: ScanEnvironment
    public let options: ScanOptions
    public let diskInfo: DiskInfoProvider

    public init(
        scanners: [any Scanner],
        environment: ScanEnvironment,
        options: ScanOptions,
        diskInfo: DiskInfoProvider
    ) {
        self.scanners = scanners
        self.environment = environment
        self.options = options
        self.diskInfo = diskInfo
    }

    public func run() -> AsyncStream<ScanUpdate> {
        AsyncStream { continuation in
            continuation.yield(.finished(ScanResult(
                startedAt: Date(), finishedAt: Date(), items: []
            )))
            continuation.finish()
        }
    }
}

/// Volume capacity / free space. Nil-safe: failure must never fail a scan.
public struct DiskInfoProvider: Sendable {
    public let volumeURL: URL?

    public init(volumeURL: URL? = nil) {
        self.volumeURL = volumeURL
    }

    public func overview() -> DiskOverview? { nil }

    public func availableBytes() -> Int64? { overview()?.availableForImportantUsage }
}
