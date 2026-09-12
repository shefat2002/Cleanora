import Foundation
import Observation

/// Drives one scan: consumes the coordinator's frozen stream, exposes
/// per-scanner progress rows, and hands the finished result to the app
/// (which persists it and routes to Results). Cancelling the owning task
/// breaks the `for await`, and the stream's onTermination cancels every
/// scanner — the stream IS the cancellation handle.
@MainActor
@Observable
final class ScanViewModel {
    enum Phase: Equatable {
        case idle
        case running
        case finished
        case cancelled
        case failed(String)
    }

    /// One progress-table row: an enabled scanner and its latest state.
    struct Row: Equatable {
        let key: ScannerKey
        let state: ScannerState
    }

    private(set) var progress = ScanProgress()
    private(set) var phase: Phase = .idle

    /// Keys of the enabled scanners — the progress denominator.
    let keys: [ScannerKey]

    var isRunning: Bool { phase == .running }
    var overallFraction: Double { progress.overallFraction(totalScanners: keys.count) }
    var discoveredBytes: Int64 { progress.discoveredBytes }
    var rows: [Row] { Self.sortedRows(progress: progress, keys: keys) }

    private let makeStream: @MainActor () -> AsyncStream<ScanUpdate>
    private let onFinish: @MainActor (ScanResult) -> Void
    private var task: Task<Void, Never>?

    init(
        keys: [ScannerKey],
        makeStream: @escaping @MainActor () -> AsyncStream<ScanUpdate>,
        onFinish: @escaping @MainActor (ScanResult) -> Void = { _ in }
    ) {
        self.keys = keys
        self.makeStream = makeStream
        self.onFinish = onFinish
    }

    convenience init(environment: AppEnvironment) {
        let options = environment.preferences.value.scanOptions
        let coordinator = environment.scanCoordinator(options: options)
        self.init(
            keys: coordinator.scanners.map(\.progressKey),
            makeStream: { coordinator.run() },
            onFinish: { result in
                // P-13: the app layer decides between the plain Results route
                // and an auto-clean (safe items, no confirmation) — including
                // the loud fallback when auto-clean had to be skipped.
                environment.scanDidFinish(result)
            }
        )
    }

    func start() {
        guard phase == .idle else { return }
        phase = .running
        task = Task { [weak self] in
            guard let self else { return }
            let stream = self.makeStream()
            for await update in stream {
                self.apply(update)
            }
            // Stream ended without a .finished event — the only way that
            // happens is cancellation.
            if self.phase == .running {
                self.phase = .cancelled
            }
        }
    }

    /// Breaking the for-await terminates the stream, which cancels the
    /// scanners. Nothing is deleted by a scan; this only stops discovery.
    func cancel() {
        task?.cancel()
    }

    /// Resets a cancelled/failed scan so it can be started again.
    func reset() {
        guard !isRunning else { return }
        progress = ScanProgress()
        phase = .idle
    }

    private func apply(_ update: ScanUpdate) {
        switch update {
        case .progress(let progress):
            self.progress = progress
        case .finished(let result):
            phase = .finished
            onFinish(result)
        case .failed(let message):
            phase = .failed(message)
        }
    }

    // MARK: - Pure presentation logic

    static func sortedRows(progress: ScanProgress, keys: [ScannerKey]) -> [Row] {
        keys.map { Row(key: $0, state: progress.state(for: $0)) }
            .sorted { ($0.key.id.sortOrder, $0.key.label) < ($1.key.id.sortOrder, $1.key.label) }
    }

    /// Secondary line under a scanner row; nil for pending rows.
    static func detailText(for state: ScannerState) -> String? {
        switch state {
        case .pending:
            return nil
        case .running(let bytes, _):
            return "Scanning… \(bytes.formattedByteCount)"
        case .completed(let totalBytes, let itemCount):
            let label = totalBytes.formattedByteCount
            return itemCount > 1 ? "\(label) across \(itemCount) items" : "\(label) found"
        case .skipped(let reason):
            return "Skipped — \(skipText(reason))"
        case .failed:
            return "This check failed"
        }
    }

    static func skipText(_ reason: SkipReason) -> String {
        switch reason {
        case .disabledByUser:
            return "turned off in Settings"
        case .pathNotFound(let path):
            return "nothing to scan at \(path)"
        case .permissionDenied:
            return "needs Full Disk Access"
        case .toolNotInstalled(let tool):
            return "\(tool) isn't installed"
        case .tooLargeToScan:
            return "too large to scan in one pass"
        }
    }

    /// U-13: the Full Disk Access banner appears as soon as any scanner
    /// reports a permission skip.
    static func permissionDeniedMessage(in progress: ScanProgress) -> String? {
        let denied = progress.states.values.contains { state in
            if case .skipped(.permissionDenied) = state { return true }
            return false
        }
        return denied ? "Full Disk Access not granted — some locations couldn't be scanned." : nil
    }
}
