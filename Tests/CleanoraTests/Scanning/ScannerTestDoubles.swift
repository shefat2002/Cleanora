import Foundation
@testable import Cleanora

/// Lifecycle recorder for scanner runs — lets tests observe start/finish and
/// therefore cancellation and concurrency, without touching production code.
actor ScanProbe {
    private(set) var started = false
    private(set) var finished = false

    func markStarted() { started = true }
    func markFinished() { finished = true }

    func waitUntilStarted(timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !started {
            guard ContinuousClock.now < deadline else { throw ProbeTimeoutError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

struct ProbeTimeoutError: Error {}

enum TrackingFailure: Sendable {
    case permissionDenied
    case generic

    var asError: any Error {
        switch self {
        case .permissionDenied: return CocoaError(.fileReadNoPermission)
        case .generic: return TrackingBoomError()
        }
    }
}

struct TrackingBoomError: Error {}

/// Scriptable scanner for coordinator tests: records start/finish on its
/// probe, can spam progress updates, sleep, throw, or produce items.
/// (`Scanner` is qualified: Foundation exports a class of the same name.)
struct TrackingScanner: Cleanora.Scanner {
    let category: ScanCategory
    let probe: ScanProbe
    let outcome: ScannerOutcome
    var delay: Duration = .zero
    var progressSpam: Int = 0
    var progressSpamAfterDelay: Int = 0
    var failure: TrackingFailure? = nil

    var progressKey: ScannerKey { ScannerKey(id: category) }
    var isPhaseOne: Bool { true }

    func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome {
        await probe.markStarted()
        if progressSpam > 0 { spam(progressSpam, onProgress) }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if progressSpamAfterDelay > 0 { spam(progressSpamAfterDelay, onProgress) }
        if let failure {
            throw failure.asError
        }
        await probe.markFinished()
        return outcome
    }

    private func spam(
        _ count: Int,
        _ onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) {
        for index in 0..<count {
            onProgress(progressKey, .running(bytesScanned: Int64(index), itemsFound: index))
        }
    }
}

/// Item factory for coordinator tests — valid, `.never`-free items.
enum TestItems {
    static func item(
        _ name: String,
        under parent: URL,
        size: Int64,
        risk: RiskLevel = .safe,
        category: ScanCategory = .applicationCaches,
        method: DeletionMethod = .trashDirectory
    ) -> CleanupItem {
        CleanupItem(
            name: name,
            appName: name,
            category: category,
            path: parent.appendingPathComponent(name, isDirectory: true),
            size: size,
            riskLevel: risk,
            reason: "test fixture",
            deletionMethod: method
        )
    }
}

/// FileManager enumeration returns `/private/var/...` spellings while
/// fixture-built URLs say `/var/...` — the classic /tmp symlink split.
/// Compare symlink-resolved paths so both spellings are equal.
func canonicalTestPath(_ url: URL) -> URL {
    url.resolvingSymlinksInPath()
}
