import Foundation

/// C-02 — one item per application cache directory directly under
/// `~/Library/Caches`: reverse-DNS bundle directories plus legacy plain-name
/// directories. Items are `.trashDirectory` (recoverable); per-bundle
/// overrides can downgrade a cache to `.review`.
public struct ApplicationCacheScanner: Scanner {
    public let category: ScanCategory = .applicationCaches
    public let progressKey: ScannerKey
    public let isPhaseOne: Bool = true

    /// Directory-name prefixes treated as reverse-DNS bundle identifiers.
    static let bundleIDPrefixes = ["com.", "org.", "net.", "io."]
    /// Cleanora's own caches are never a cleanup target.
    static let ownBundlePrefix = "com.cleanora."

    public init() {
        self.progressKey = ScannerKey(id: .applicationCaches)
    }

    public func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome {
        let caches = environment.caches
        if let reason = ScannerGuards.skipReason(root: caches, environment: environment) {
            return .skipped(reason)
        }
        guard !Task.isCancelled else { return .produced([]) }
        onProgress(progressKey, .running(bytesScanned: 0, itemsFound: 0))

        let walker = FileSystemWalker()
        let calculator = DirectorySizeCalculator()
        let children = ((try? walker.children(of: caches)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var items: [CleanupItem] = []
        var discoveredBytes: Int64 = 0

        for child in children {
            if Task.isCancelled { break }
            let values = try? child.resourceValues(forKeys: FileSystemWalker.resourceKeySet)
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let name = child.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            guard !name.hasPrefix(Self.ownBundlePrefix) else { continue }

            let bundleID = Self.bundleIdentifier(forDirectoryNamed: name)
            let appName = FriendlyNaming.appName(forBundleID: bundleID, fallbackName: name)
            let override = bundleID.flatMap { AppCacheOverrides.matching(bundleID: $0) }

            let measurement = await calculator.measure(at: child)
            guard measurement.fileCount > 0 else { continue } // empty dir: nothing to clean
            discoveredBytes += measurement.bytes
            onProgress(progressKey, .running(
                bytesScanned: discoveredBytes, itemsFound: items.count + 1
            ))

            let reason = override?.reason
                ?? "\(appName) stores temporary cache data here and recreates it whenever it is needed."
            items.append(CleanupItem(
                name: appName,
                appName: appName,
                category: .applicationCaches,
                path: child,
                size: measurement.bytes,
                fileCount: measurement.fileCount,
                riskLevel: override?.riskLevel ?? .safe,
                reason: reason,
                deletionMethod: .trashDirectory
            ))
        }
        return .produced(items)
    }

    /// "com.google.Chrome" → "com.google.Chrome"; "Google" or "pip" → nil.
    static func bundleIdentifier(forDirectoryNamed name: String) -> String? {
        guard name.contains("."),
              bundleIDPrefixes.contains(where: { name.hasPrefix($0) })
        else { return nil }
        return name
    }
}
