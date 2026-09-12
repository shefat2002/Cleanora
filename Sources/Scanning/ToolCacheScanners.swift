import Foundation

/// P-02..P-05 — the per-tool package-manager cache scanners share one shape:
/// one or more home-derived cache roots, `.safe` items cleaned with
/// `.removeContents` (the tool recreates the contents), per-tool progress row,
/// and `.skipped(.toolNotInstalled)` when no root of the tool exists at all
/// (an installed-but-empty tool has no cache yet, so "absent cache" is the
/// only observable, fixture-injectable absence signal).
///
/// The four scanners below are thin shells over `ToolCacheScanning.run` so
/// each keeps its own type, row key and copy.
enum ToolCacheScanning {
    struct RootSpec: Sendable {
        /// Human item name ("npm package cache").
        let name: String
        /// Path components relative to the environment home.
        let pathComponents: [String]
        /// Why removing this root is safe — the item's user-facing reason.
        let reason: String

        func url(in environment: ScanEnvironment) -> URL {
            environment.home.appending(pathComponents)
        }
    }

    /// Measures every present root and returns one `.safe` item per non-empty
    /// one. All roots absent → `.toolNotInstalled(tool)`; every present root
    /// unreadable → `.permissionDenied`. Progress updates land on `rowKey`.
    static func run(
        tool: String,
        rowKey: ScannerKey,
        appName: String,
        roots: [RootSpec],
        environment: ScanEnvironment,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async -> ScannerOutcome {
        let present = roots
            .map { $0.url(in: environment) }
            .filter { environment.exists($0) }
        guard !present.isEmpty else {
            onProgress(rowKey, .skipped(.toolNotInstalled(tool)))
            return .skipped(.toolNotInstalled(tool))
        }
        if let reason = ScannerGuards.skipReason(roots: present, environment: environment) {
            onProgress(rowKey, .skipped(reason))
            return .skipped(reason)
        }
        guard !Task.isCancelled else { return .produced([]) }
        onProgress(rowKey, .running(bytesScanned: 0, itemsFound: 0))

        let calculator = DirectorySizeCalculator()
        var items: [CleanupItem] = []
        var discoveredBytes: Int64 = 0

        for spec in roots where present.contains(spec.url(in: environment)) {
            if Task.isCancelled { break }
            let root = spec.url(in: environment)
            let measurement = await calculator.measure(at: root)
            guard measurement.fileCount > 0 else { continue } // empty: nothing to clean
            discoveredBytes += measurement.bytes
            onProgress(rowKey, .running(
                bytesScanned: discoveredBytes, itemsFound: items.count + 1
            ))
            items.append(CleanupItem(
                name: spec.name,
                appName: appName,
                category: .developerData,
                path: root,
                size: measurement.bytes,
                fileCount: measurement.fileCount,
                riskLevel: .safe,
                reason: spec.reason,
                deletionMethod: .removeContents
            ))
        }
        // Terminal row state from the scanner itself: inside the developer
        // composite only the composite key is terminalized by the
        // coordinator, so a tool that skips this would leave its row running.
        onProgress(rowKey, .completed(
            totalBytes: discoveredBytes, itemCount: items.count
        ))
        return .produced(items)
    }
}

// MARK: - P-02 Homebrew

/// `~/Library/Caches/Homebrew` including its `downloads` subtree — bottles
/// and API metadata Homebrew re-downloads on demand.
public struct HomebrewScanner: Scanner {
    public let category: ScanCategory = .developerData
    public let progressKey: ScannerKey
    public let isPhaseOne: Bool = false

    static let roots: [ToolCacheScanning.RootSpec] = [
        .init(
            name: "Homebrew cache",
            pathComponents: ["Library", "Caches", "Homebrew"],
            reason: "Homebrew keeps downloaded packages and metadata here and re-downloads them when needed."
        ),
    ]

    public init() {
        self.progressKey = ScannerKey(id: .developerData, label: "Homebrew")
    }

    public func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome {
        await ToolCacheScanning.run(
            tool: "Homebrew",
            rowKey: progressKey,
            appName: "Homebrew",
            roots: Self.roots,
            environment: environment,
            onProgress: onProgress
        )
    }
}

// MARK: - P-03 npm

/// `~/.npm/_cacache` (package content cache) and `~/.npm/_logs` (run logs).
/// NOTE: `_logs` sits outside `_cacache` and needs its own SafetyPolicy root.
public struct NpmScanner: Scanner {
    public let category: ScanCategory = .developerData
    public let progressKey: ScannerKey
    public let isPhaseOne: Bool = false

    static let roots: [ToolCacheScanning.RootSpec] = [
        .init(
            name: "npm package cache",
            pathComponents: [".npm", "_cacache"],
            reason: "npm caches every downloaded package here; installs re-fetch whatever is missing."
        ),
        .init(
            name: "npm logs",
            pathComponents: [".npm", "_logs"],
            reason: "npm writes a debug log for every command; old logs are diagnostics history only."
        ),
    ]

    public init() {
        self.progressKey = ScannerKey(id: .developerData, label: "npm")
    }

    public func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome {
        await ToolCacheScanning.run(
            tool: "npm",
            rowKey: progressKey,
            appName: "npm",
            roots: Self.roots,
            environment: environment,
            onProgress: onProgress
        )
    }
}

// MARK: - P-04 pip

/// `~/Library/Caches/pip` (macOS default) and `~/.cache/pip` (XDG layout).
/// NOTE: the XDG location needs its own SafetyPolicy root.
public struct PipScanner: Scanner {
    public let category: ScanCategory = .developerData
    public let progressKey: ScannerKey
    public let isPhaseOne: Bool = false

    static let roots: [ToolCacheScanning.RootSpec] = [
        .init(
            name: "pip cache",
            pathComponents: ["Library", "Caches", "pip"],
            reason: "pip caches downloaded wheels so reinstalls are faster; any missing wheel is re-downloaded."
        ),
        .init(
            name: "pip cache (XDG)",
            pathComponents: [".cache", "pip"],
            reason: "pip caches downloaded wheels here when following the XDG layout; reinstalls re-fetch what is missing."
        ),
    ]

    public init() {
        self.progressKey = ScannerKey(id: .developerData, label: "pip")
    }

    public func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome {
        await ToolCacheScanning.run(
            tool: "pip",
            rowKey: progressKey,
            appName: "pip",
            roots: Self.roots,
            environment: environment,
            onProgress: onProgress
        )
    }
}

// MARK: - P-05 Yarn

/// `~/Library/Caches/Yarn` (v1 offline mirror) and `~/.yarn/berry/cache`
/// (Berry's global cache).
public struct YarnScanner: Scanner {
    public let category: ScanCategory = .developerData
    public let progressKey: ScannerKey
    public let isPhaseOne: Bool = false

    static let roots: [ToolCacheScanning.RootSpec] = [
        .init(
            name: "Yarn cache",
            pathComponents: ["Library", "Caches", "Yarn"],
            reason: "Yarn caches downloaded packages here; installs re-fetch whatever is missing."
        ),
        .init(
            name: "Yarn berry cache",
            pathComponents: [".yarn", "berry", "cache"],
            reason: "Yarn Berry caches every package as a zip here; installs re-fetch missing entries."
        ),
    ]

    public init() {
        self.progressKey = ScannerKey(id: .developerData, label: "Yarn")
    }

    public func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome {
        await ToolCacheScanning.run(
            tool: "Yarn",
            rowKey: progressKey,
            appName: "Yarn",
            roots: Self.roots,
            environment: environment,
            onProgress: onProgress
        )
    }
}
