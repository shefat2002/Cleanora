import Foundation

/// The single seam between the UI and the scan engine. Engine scanner types
/// are constructed nowhere else in the app.
///
/// The catalog always returns the full phase-one set in display order; the
/// coordinator filters by `options.enabledCategories` itself and pre-seeds
/// disabled scanners as `.skipped(.disabledByUser)`, so Settings toggles
/// produce visible, explained rows instead of missing ones. The Phase-2
/// developer composite appends here behind `options.includeDeveloperData`
/// when those scanners land.
enum ScannerCatalog {
    static func scanners(for options: ScanOptions, environment: ScanEnvironment) -> [any Scanner] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLEANORA_FIXTURE_HOME"] != nil {
            return fixtureScanners(in: environment)
        }
        #endif
        return ScanCoordinator.phaseOneScanners(environment: environment)
    }

    #if DEBUG
    /// Fixture QA seam (I-02): the real scanners against CLEANORA_FIXTURE_HOME
    /// — ScanEnvironment.live() re-roots everything, so QA exercises the
    /// genuine engine. TempScanner's second root is kept inside the fixture
    /// home so fixture runs never read the real /private/tmp.
    private static func fixtureScanners(in environment: ScanEnvironment) -> [any Scanner] {
        [
            ApplicationCacheScanner(),
            BrowserCacheScanner(),
            TempScanner(sharedTempRoot: environment.temporaryRoot),
            LogScanner(),
            TrashScanner(),
        ]
    }
    #endif
}
