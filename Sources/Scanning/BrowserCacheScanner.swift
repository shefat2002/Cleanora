import Foundation

/// C-03 — per-profile browser cache items, driven by `BrowserCatalog`.
///
/// Items always point at the per-profile cache SUBdirectories (`.removeContents`),
/// never at the profile directory itself: profiles hold bookmarks and state
/// and must survive a cleanup. Only directories that exist and are readable
/// are reported.
public struct BrowserCacheScanner: Scanner {
    public let category: ScanCategory = .browserCaches
    public let progressKey: ScannerKey
    public let isPhaseOne: Bool = true

    public init() {
        self.progressKey = ScannerKey(id: .browserCaches)
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
        var items: [CleanupItem] = []
        var discoveredBytes: Int64 = 0
        var safariDenied = false

        for browser in BrowserCatalog.all {
            if Task.isCancelled { break }
            let base = caches.appending(browser.baseComponents)
            guard environment.exists(base) else { continue }
            guard environment.readable(base) else {
                if browser.layout == .wholeDirectory { safariDenied = true }
                continue
            }

            switch browser.layout {
            case .wholeDirectory:
                let measurement = await calculator.measure(at: base)
                guard measurement.fileCount > 0 else { continue }
                discoveredBytes += measurement.bytes
                onProgress(progressKey, .running(
                    bytesScanned: discoveredBytes, itemsFound: items.count + 1
                ))
                // Safari is .review → recoverable trash method, never removeContents.
                items.append(CleanupItem(
                    name: browser.name,
                    appName: browser.name,
                    category: .browserCaches,
                    path: base,
                    size: measurement.bytes,
                    fileCount: measurement.fileCount,
                    riskLevel: .review,
                    reason: browser.reason,
                    deletionMethod: .trashDirectory
                ))

            case .chromium, .firefox:
                let subdirectories = browser.layout == .chromium
                    ? BrowserCatalog.chromiumCacheDirectories
                    : BrowserCatalog.firefoxCacheDirectories
                // Firefox nests its profiles one level deeper: Firefox/Profiles/<profile>.
                let profileBase: URL
                if browser.layout == .firefox {
                    profileBase = base.appendingPathComponent("Profiles", isDirectory: true)
                    guard environment.exists(profileBase) else { continue }
                } else {
                    profileBase = base
                }
                for profile in Self.profiles(of: profileBase, walker: walker) {
                    if Task.isCancelled { break }
                    for subdirectory in subdirectories {
                        let dir = profile.appendingPathComponent(subdirectory, isDirectory: true)
                        guard environment.exists(dir), environment.readable(dir) else { continue }
                        let measurement = await calculator.measure(at: dir)
                        guard measurement.fileCount > 0 else { continue }
                        discoveredBytes += measurement.bytes
                        onProgress(progressKey, .running(
                            bytesScanned: discoveredBytes, itemsFound: items.count + 1
                        ))
                        items.append(CleanupItem(
                            name: "\(browser.name) — \(profile.lastPathComponent) (\(subdirectory))",
                            appName: browser.name,
                            category: .browserCaches,
                            path: dir,
                            size: measurement.bytes,
                            fileCount: measurement.fileCount,
                            riskLevel: .safe,
                            reason: browser.reason,
                            deletionMethod: .removeContents
                        ))
                    }
                }
            }
        }

        // A TCC denial on Safari's cache surfaces as the scanner's skip — but
        // only when nothing else was found, so Chromium items are never lost.
        if items.isEmpty, safariDenied {
            return .skipped(.permissionDenied(caches.appending(BrowserCatalog.safari.baseComponents).path))
        }
        return .produced(items)
    }

    /// Profile directories under a browser base: visible, real directories,
    /// symlinks excluded (I7).
    static func profiles(of base: URL, walker: FileSystemWalker) -> [URL] {
        ((try? walker.children(of: base)) ?? [])
            .filter { child in
                let values = try? child.resourceValues(forKeys: FileSystemWalker.resourceKeySet)
                return values?.isDirectory == true
                    && values?.isSymbolicLink != true
                    && !child.lastPathComponent.hasPrefix(".")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
