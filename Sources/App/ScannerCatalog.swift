import Foundation

/// The single seam between the UI and the scan engine. Engine scanner types
/// are constructed nowhere else in the app.
///
/// The catalog mirrors `options.enabledCategories`, so Settings toggles gate
/// real scans with no UI-specific knowledge. The Phase-2 developer composite
/// (Xcode, Homebrew, npm, pip, Yarn, Docker) appends here behind
/// `options.includeDeveloperData` when those scanners land.
enum ScannerCatalog {
    static func scanners(for options: ScanOptions, environment: ScanEnvironment) -> [any Scanner] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLEANORA_FIXTURE_HOME"] != nil {
            return fixtureScanners(for: options, in: environment)
        }
        #endif

        var scanners: [any Scanner] = []
        let enabled = options.enabledCategories
        if enabled.contains(.applicationCaches) {
            scanners.append(ApplicationCacheScanner())
        }
        if enabled.contains(.browserCaches) {
            scanners.append(BrowserCacheScanner())
        }
        if enabled.contains(.temporaryFiles) {
            scanners.append(TempScanner())
        }
        if enabled.contains(.logs) {
            scanners.append(LogScanner())
        }
        if enabled.contains(.trash) {
            scanners.append(TrashScanner())
        }
        return scanners
    }

    #if DEBUG
    /// Fixture QA seam (I-02 companion): small deterministic scanners that
    /// report what actually sits in CLEANORA_FIXTURE_HOME, with a short
    /// delay so progress rows are visible during QA runs. Items are real
    /// paths under the fixture home — a directory that exists only for
    /// this purpose.
    private static func fixtureScanners(
        for options: ScanOptions,
        in environment: ScanEnvironment
    ) -> [any Scanner] {
        var scanners: [any Scanner] = []
        for category in ScanCategory.phaseOne where options.enabledCategories.contains(category) {
            let root = fixtureRoot(for: category, in: environment)
            let items = fixtureItems(category: category, root: root)
            let outcome: ScannerOutcome = items.isEmpty
                ? .skipped(.pathNotFound(root.path))
                : .produced(items)
            scanners.append(MockScanner(category: category, result: outcome, delay: .milliseconds(400)))
        }
        return scanners
    }

    private static func fixtureRoot(for category: ScanCategory, in environment: ScanEnvironment) -> URL {
        switch category {
        case .applicationCaches: return environment.caches
        case .browserCaches: return environment.caches.appendingPathComponent("Browsers", isDirectory: true)
        case .temporaryFiles: return environment.temporaryRoot
        case .logs: return environment.logs
        case .trash: return environment.trash
        case .developerData, .largeFiles: return environment.caches
        }
    }

    private static func fixtureItems(category: ScanCategory, root: URL) -> [CleanupItem] {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        ), !children.isEmpty else { return [] }

        return children.map { child in
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectory = values?.isDirectory ?? false
            let size = Int64(isDirectory ? directorySize(child) : (values?.fileSize ?? 0))
            let groupsByApp = category == .applicationCaches || category == .browserCaches
            return CleanupItem(
                name: child.lastPathComponent,
                appName: groupsByApp ? child.lastPathComponent : nil,
                category: category,
                path: child,
                size: max(0, size),
                riskLevel: .safe,
                reason: "Regenerable \(category.displayName.lowercased()) found in the fixture home.",
                deletionMethod: .removeContents,
                confirmationLevel: category == .trash ? .destructive : .standard
            )
        }
    }

    private static func directorySize(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total = 0
        for case let file as URL in enumerator {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
    #endif
}
