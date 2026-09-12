import Foundation

/// P-07 — the developer composite: runs the six per-tool scanners
/// concurrently (TaskGroup) behind a single `Scanner`, merges their items
/// into one outcome, and fans their progress out as per-tool rows while its
/// own "Developer Data" row tracks the aggregate.
///
/// Gated by `options.includeDeveloperData` — off means one clean
/// `.skipped(.disabledByUser)` row and no fan-out rows at all. When every
/// tool skips, the composite completes empty: the per-tool rows carry the
/// skip reasons, so the composite has nothing of its own to report.
public struct DeveloperScanner: Scanner, ProgressFanOutScanner {
    public let category: ScanCategory = .developerData
    public let progressKey: ScannerKey
    public let isPhaseOne: Bool = false

    /// The Phase-2 tool set. DockerScanner keeps its production detectors;
    /// tests construct a composite with injected doubles where determinism
    /// matters (the host must not influence engine tests).
    public static func standardScanners() -> [any Scanner] {
        [
            XcodeScanner(),
            HomebrewScanner(),
            NpmScanner(),
            PipScanner(),
            YarnScanner(),
            DockerScanner(),
        ]
    }

    private let subScanners: [any Scanner]

    public init(subScanners: [any Scanner] = DeveloperScanner.standardScanners()) {
        self.progressKey = ScannerKey(id: .developerData, label: "Developer Data")
        self.subScanners = subScanners
    }

    public func rowKeys(
        environment: ScanEnvironment,
        options: ScanOptions
    ) -> [ScannerKey] {
        guard options.includeDeveloperData else { return [progressKey] }
        return [progressKey] + subScanners.flatMap { scanner in
            (scanner as? any ProgressFanOutScanner)?
                .rowKeys(environment: environment, options: options)
                ?? [scanner.progressKey]
        }
    }

    public func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome {
        guard options.includeDeveloperData else { return .skipped(.disabledByUser) }
        guard !Task.isCancelled else { return .produced([]) }
        onProgress(progressKey, .running(bytesScanned: 0, itemsFound: 0))

        var items: [CleanupItem] = []
        await withTaskGroup(of: ScannerOutcome.self) { group in
            for scanner in subScanners {
                group.addTask {
                    await Self.runTool(
                        scanner, environment: environment, options: options, onProgress: onProgress
                    )
                }
            }
            for await outcome in group {
                if case .produced(let produced) = outcome {
                    items.append(contentsOf: produced)
                }
                // One tool finished — move the aggregate row forward.
                onProgress(progressKey, .running(
                    bytesScanned: items.reduce(Int64(0)) { $0 + $1.size },
                    itemsFound: items.count
                ))
            }
        }
        return .produced(items)
    }

    /// One tool's run; a throwing tool degrades to a failed row on its own
    /// key instead of failing the composite.
    private static func runTool(
        _ scanner: any Scanner,
        environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async -> ScannerOutcome {
        do {
            return try await scanner.scan(
                in: environment, options: options, onProgress: onProgress
            )
        } catch {
            onProgress(scanner.progressKey, ScanCoordinator.terminalState(for: error, key: scanner.progressKey))
            return .produced([])
        }
    }
}
