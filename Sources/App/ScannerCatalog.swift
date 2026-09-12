import Foundation

/// The single seam between the UI and the scan engine. Engine scanner types
/// are constructed nowhere else in the app.
///
/// The coordinator filters by `options.enabledCategories` itself and pre-seeds
/// disabled scanners as `.skipped(.disabledByUser)`, so Settings toggles
/// produce visible, explained rows instead of missing ones.
enum ScannerCatalog {
    static func scanners(for options: ScanOptions, environment: ScanEnvironment) -> [any Scanner] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLEANORA_FIXTURE_HOME"] != nil {
            var scanners = fixtureScanners(in: environment)
            if options.includeDeveloperData {
                // Phase-2 scanners against the fixture home, keeping the
                // sealed-off fixture temp root for phase one.
                let developerScanners: [any Scanner] = ScanCoordinator
                    .fullScanners(environment: environment, options: options)
                    .filter {
                        $0.category == .developerData || $0.category == .largeFiles
                    }
                scanners.append(contentsOf: developerScanners)
            }
            return withLargeFilesScanned(scanners)
        }
        #endif
        let scanners = options.includeDeveloperData
            ? ScanCoordinator.fullScanners(environment: environment, options: options)
            : ScanCoordinator.phaseOneScanners(environment: environment)
        return withLargeFilesScanned(scanners)
    }

    /// Large files are informational and review-only (never preselected,
    /// never auto-cleaned), so they are scanned regardless of the developer
    /// gate. `fullScanners` may already include the scanner — then this is a
    /// no-op; if a later reconciled factory drops it, the catalog keeps the
    /// feature alive at this single sanctioned construction site.
    private static func withLargeFilesScanned(_ scanners: [any Scanner]) -> [any Scanner] {
        guard !scanners.contains(where: { $0.category == .largeFiles }) else { return scanners }
        return scanners + [LargeFileScanner()]
    }

    /// P-13: stored options carry the developer gate as a flag, but the
    /// coordinator gates on `enabledCategories` — so the flag is mirrored
    /// into the category set here, at the single seam between UI and engine.
    /// Large Files has no Settings toggle on purpose: it is an informational,
    /// review-only listing (never preselected, never auto-cleaned), so it is
    /// always scanned.
    static func resolvedOptions(_ options: ScanOptions) -> ScanOptions {
        var resolved = options
        if resolved.includeDeveloperData {
            resolved.enabledCategories.insert(.developerData)
        }
        resolved.enabledCategories.insert(.largeFiles)
        return resolved
    }

    #if DEBUG
    /// Fixture QA seam (I-02): the real scanners against CLEANORA_FIXTURE_HOME
    /// — ScanEnvironment.live() re-roots everything, so QA exercises the
    /// genuine engine. TempScanner's second root is a distinct path inside
    /// the fixture home: still sealed off the real /private/tmp, and without
    /// the same-URL-twice overlap that would double-count progress numbers
    /// (the coordinator dedupes final items, but live bytesScanned would
    /// still double).
    private static func fixtureScanners(in environment: ScanEnvironment) -> [any Scanner] {
        [
            ApplicationCacheScanner(),
            BrowserCacheScanner(),
            TempScanner(
                sharedTempRoot: environment.temporaryRoot
                    .appendingPathComponent("shared", isDirectory: true)
            ),
            LogScanner(),
            TrashScanner(),
        ]
    }
    #endif
}
