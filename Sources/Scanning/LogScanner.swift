import Foundation

/// C-05 — old logs: `~/Library/Logs`, `~/Library/Logs/DiagnosticReports` and
/// `~/Library/Application Support/CrashReporter`.
///
/// Only entries untouched for at least 7 days are "old logs"; anything recent
/// is live data. Directories become `.trashDirectory` items, loose files
/// `.moveToTrash` — both recoverable.
public struct LogScanner: Scanner {
    public let category: ScanCategory = .logs
    public let progressKey: ScannerKey
    public let isPhaseOne: Bool = true

    /// Entries newer than this are live and skipped.
    public static let stalenessCutoff: TimeInterval = 7 * 86_400

    /// Reported via its own dedicated root below — scanning it as an entry of
    /// `env.logs` as well would double count.
    static let dedicatedSubrootName = "DiagnosticReports"

    public init() {
        self.progressKey = ScannerKey(id: .logs)
    }

    public func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome {
        let crashReporter = environment.applicationSupport
            .appendingPathComponent("CrashReporter", isDirectory: true)
        let roots: [(url: URL, excludedNames: Set<String>)] = [
            (environment.logs, [Self.dedicatedSubrootName]),
            (environment.diagnosticReports, []),
            (crashReporter, []),
        ]
        if let reason = ScannerGuards.skipReason(
            roots: roots.map(\.url), environment: environment
        ) {
            return .skipped(reason)
        }
        guard !Task.isCancelled else { return .produced([]) }
        onProgress(progressKey, .running(bytesScanned: 0, itemsFound: 0))

        let walker = FileSystemWalker()
        let calculator = DirectorySizeCalculator()
        var items: [CleanupItem] = []
        var discoveredBytes: Int64 = 0

        for root in roots {
            if Task.isCancelled { break }
            guard environment.exists(root.url), environment.readable(root.url) else { continue }
            let children = ((try? walker.children(of: root.url)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for child in children {
                if Task.isCancelled { break }
                guard !root.excludedNames.contains(child.lastPathComponent) else { continue }
                let values = try? child.resourceValues(forKeys: FileSystemWalker.resourceKeySet)
                guard values?.isSymbolicLink != true else { continue }
                let isDirectory = values?.isDirectory == true
                let isRegularFile = values?.isRegularFile == true
                guard isDirectory || isRegularFile else { continue }
                guard ScannerGuards.isStale(
                    modificationDate: values?.contentModificationDate,
                    olderThan: Self.stalenessCutoff
                ) else { continue }

                let measurement: DirectorySizeCalculator.Result
                if isDirectory {
                    measurement = await calculator.measure(at: child)
                } else {
                    measurement = DirectorySizeCalculator.Result(
                        bytes: ScannerGuards.fileSize(from: values),
                        fileCount: 1
                    )
                }
                guard measurement.fileCount > 0 else { continue }
                discoveredBytes += measurement.bytes
                onProgress(progressKey, .running(
                    bytesScanned: discoveredBytes, itemsFound: items.count + 1
                ))

                let name = child.lastPathComponent
                items.append(CleanupItem(
                    name: name,
                    appName: nil,
                    category: .logs,
                    path: child,
                    size: measurement.bytes,
                    fileCount: measurement.fileCount,
                    riskLevel: .safe,
                    reason: isDirectory
                        ? "\(name) has not written a log entry in over 7 days; apps recreate their log folders when needed."
                        : "\(name) is a log file older than 7 days; it is diagnostics history, not live data.",
                    deletionMethod: isDirectory ? .trashDirectory : .moveToTrash
                ))
            }
        }
        return .produced(items)
    }
}
