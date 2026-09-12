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
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task(priority: .userInitiated) {
                await self.execute(into: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// The standard phase-one scanner set, in display order. Apps feed this
    /// (or a filtered variant) straight into `init(scanners:...)`.
    public static func phaseOneScanners(environment: ScanEnvironment) -> [any Scanner] {
        [
            ApplicationCacheScanner(),
            BrowserCacheScanner(),
            TempScanner(),
            LogScanner(),
            TrashScanner(),
        ]
    }

    // MARK: - Execution

    private func execute(into continuation: AsyncStream<ScanUpdate>.Continuation) async {
        let startedAt = Date()
        let freeSpaceBefore = diskInfo.availableBytes()

        let enabled = scanners
            .filter { options.enabledCategories.contains($0.category) }
            .sorted { $0.category.sortOrder < $1.category.sortOrder }
        let disabled = scanners
            .filter { !options.enabledCategories.contains($0.category) }
            .sorted { $0.category.sortOrder < $1.category.sortOrder }

        var initialStates: [ScannerKey: ScannerState] = [:]
        for scanner in enabled { initialStates[scanner.progressKey] = .pending }
        for scanner in disabled { initialStates[scanner.progressKey] = .skipped(.disabledByUser) }

        let hub = ProgressHub(initialStates: initialStates)
        let emitProgress: @Sendable (ScanProgress) -> Void = { progress in
            continuation.yield(.progress(progress))
        }
        await hub.begin(emit: emitProgress)

        var runs: [ScannerRun] = []
        await withTaskGroup(of: ScannerRun.self) { group in
            for (index, scanner) in enabled.enumerated() {
                group.addTask {
                    await self.runScanner(scanner, order: index, hub: hub, emit: emitProgress)
                }
            }
            for await run in group {
                await hub.record(run.key, run.state, emit: emitProgress)
                runs.append(run)
            }
        }

        // The consumer is gone (that's what cancellation means here) — finish
        // quietly instead of publishing a result nobody can observe.
        guard !Task.isCancelled else {
            continuation.finish()
            return
        }

        await hub.flush(emit: emitProgress)

        // Group completion order is nondeterministic; restore scanner order so
        // dedup's equal-path tie-break ("first producer wins") is stable.
        let collected = runs.sorted { $0.order < $1.order }.flatMap(\.items)
        let items = Self.deduplicate(collected)
        continuation.yield(.finished(ScanResult(
            startedAt: startedAt,
            finishedAt: Date(),
            items: items,
            summaries: Self.summarize(items),
            freeSpaceBefore: freeSpaceBefore,
            scannerKeys: enabled.map { $0.progressKey }
        )))
        continuation.finish()
    }

    /// Runs one scanner, mapping its outcome or any thrown error onto a
    /// terminal progress state. Never rethrows — one scanner failing must not
    /// touch the others.
    private func runScanner(
        _ scanner: any Scanner,
        order: Int,
        hub: ProgressHub,
        emit: @escaping @Sendable (ScanProgress) -> Void
    ) async -> ScannerRun {
        let key = scanner.progressKey
        do {
            let outcome = try await scanner.scan(
                in: environment,
                options: options,
                onProgress: { observedKey, state in
                    // Fire-and-forget: the hub throttles and coalesces.
                    Task { await hub.record(observedKey, state, emit: emit) }
                }
            )
            switch outcome {
            case .produced(let items):
                let bytes = items.reduce(Int64(0)) { $0 + $1.size }
                return ScannerRun(
                    order: order,
                    key: key,
                    state: .completed(totalBytes: bytes, itemCount: items.count),
                    items: items
                )
            case .skipped(let reason):
                return ScannerRun(order: order, key: key, state: .skipped(reason), items: [])
            }
        } catch {
            return ScannerRun(
                order: order,
                key: key,
                state: Self.terminalState(for: error, key: key),
                items: []
            )
        }
    }

    /// Error → terminal state. Permission errors become a `.skipped` row (the
    /// UI offers the Full Disk Access fix), everything else a `.failed` row.
    /// `CancellationError` aborts quietly: the whole run is tearing down.
    static func terminalState(for error: Error, key: ScannerKey) -> ScannerState {
        if error is CancellationError {
            return .failed("Cancelled")
        }
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoPermission {
            return .skipped(.permissionDenied(key.label))
        }
        if let posix = error as? POSIXError, posix.code == .EACCES {
            return .skipped(.permissionDenied(key.label))
        }
        return .failed("\(key.label) failed: \(error.localizedDescription)")
    }

    // MARK: - O-02: dedup + summarize

    /// I8 — overlapping scanners must not double count. When one item's path
    /// contains another's, the DEEPEST path wins and its ancestors are
    /// dropped; identical paths collapse to the first producer's item. The
    /// surviving items keep their original relative order.
    static func deduplicate(_ items: [CleanupItem]) -> [CleanupItem] {
        struct Entry {
            let item: CleanupItem
            let path: String
            let index: Int
        }

        let entries = items.enumerated().map { index, item in
            Entry(item: item, path: PathNormalizer.canonicalized(item.path).path, index: index)
        }
        let deepestFirst = entries.sorted { lhs, rhs in
            let lhsDepth = lhs.path.split(separator: "/").count
            let rhsDepth = rhs.path.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
            return lhs.index < rhs.index
        }

        var kept: [Entry] = []
        var keptPaths: [String] = []
        for entry in deepestFirst {
            // An ancestor (or duplicate) of an already-kept, deeper item is
            // fully covered by it — drop it.
            let isCovered = keptPaths.contains { keptPath in
                keptPath == entry.path || keptPath.hasPrefix(entry.path + "/")
            }
            guard !isCovered else { continue }
            kept.append(entry)
            keptPaths.append(entry.path)
        }
        return kept.sorted { $0.index < $1.index }.map(\.item)
    }

    /// One summary per category that has items, in scan order, with the
    /// preselected (.safe) / review split the Results screen shows.
    static func summarize(_ items: [CleanupItem]) -> [CategorySummary] {
        var byCategory: [ScanCategory: [CleanupItem]] = [:]
        for item in items {
            byCategory[item.category, default: []].append(item)
        }
        return ScanCategory.scanOrder.compactMap { category in
            guard let group = byCategory[category], !group.isEmpty else { return nil }
            return CategorySummary(
                category: category,
                totalBytes: group.reduce(0) { $0 + $1.size },
                itemCount: group.count,
                preselectedBytes: group
                    .filter { $0.riskLevel.isPreselected }
                    .reduce(0) { $0 + $1.size },
                reviewBytes: group
                    .filter { $0.riskLevel == .review }
                    .reduce(0) { $0 + $1.size }
            )
        }
    }

    private struct ScannerRun: Sendable {
        let order: Int
        let key: ScannerKey
        let state: ScannerState
        let items: [CleanupItem]
    }
}

/// Volume capacity / free space. Nil-safe: failure must never fail a scan.
public struct DiskInfoProvider: Sendable {
    public let volumeURL: URL?

    /// The root volume, used when no URL is injected.
    static let defaultVolume = URL(fileURLWithPath: "/", isDirectory: true)

    public init(volumeURL: URL? = nil) {
        self.volumeURL = volumeURL
    }

    public func overview() -> DiskOverview? {
        let url = volumeURL ?? Self.defaultVolume
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = values?.volumeTotalCapacity,
              let available = values?.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskOverview(
            totalCapacity: Int64(total),
            availableForImportantUsage: available
        )
    }

    public func availableBytes() -> Int64? { overview()?.availableForImportantUsage }
}
