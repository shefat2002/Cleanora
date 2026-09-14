import AppKit
import Foundation
import Observation

/// What the UI needs to know about filesystem permissions, injected so the
/// dashboard and permission banner never talk to TCC directly. The default
/// implementation delegates to PermissionManager (Cleaning layer, K-05) —
/// this seam exists so views never import engine types and tests can inject
/// stubs. The AppKit deep link lives here because the Cleaning layer is
/// UI-free by layering rule.
struct PermissionProbe: Sendable {
    var hasFullDiskAccess: @Sendable () -> Bool
    var openFullDiskAccessSettings: @MainActor @Sendable () -> Void

    static func live(environment: ScanEnvironment) -> PermissionProbe {
        let manager = PermissionManager(
            home: environment.home,
            openSettings: {
                if let url = PermissionManager.fullDiskAccessSettingsURL {
                    NSWorkspace.shared.open(url)
                }
            }
        )
        return PermissionProbe(
            hasFullDiskAccess: {
                // Missing canaries (fixture homes) are not denials — only an
                // actual TCC refusal raises the banner.
                let status = manager.probe()
                return ![
                    status.caches, status.logs, status.trash, status.safari,
                ].contains(.permissionDenied)
            },
            openFullDiskAccessSettings: {
                manager.openFullDiskAccessSettings()
            }
        )
    }
}

/// Process-wide dependency container. Views and view models receive their
/// engine objects from here; nothing constructs engines on its own.
@MainActor
@Observable
final class AppEnvironment {
    let preferences: PreferencesStore
    let navigation = NavigationState()
    let scanEnvironment: ScanEnvironment

    /// Freshest scan result; Dashboard and Results read this.
    private(set) var lastScanResult: ScanResult?
    /// Report of the most recent cleanup; Completion reads this.
    private(set) var lastCleanupReport: CleanupReport?
    /// Set by the confirmation sheet, consumed and cleared by CleaningView.
    private(set) var pendingCleaning: CleaningRequest?
    /// Non-nil when auto-clean was requested but skipped (P-13): Results
    /// states out loud why it did not clean by itself.
    private(set) var autoCleanFallbackMessage: String?
    /// Set when a cleanup was cancelled partway; the next Results appearance
    /// re-derives its view model and drops already-removed items.
    private(set) var resultsNeedReconciliation = false
    /// Launch-at-login row status (P-15): success copy or the ServiceManagement
    /// error, so a failed registration is loud instead of a dead toggle.
    private(set) var loginItemStatusMessage: String?
    /// M-07: a "Run now"/scheduled run is executing; Settings disables the
    /// button while this is true.
    private(set) var isScheduledRunRunning = false

    private let appDirectories: AppDirectories
    private let permissionProbe: PermissionProbe
    private let loginItem: LoginItemController
    private let fileRevealer: FileRevealer
    let folderPicker: FolderPicker
    let startupItems: StartupItemsController
    private var cachedHistoryStore: ScanHistoryStore?
    /// Cached duplicate-finder state (M-04). Route navigation rebuilds
    /// screens, and a duplicate hunt is expensive — the view model (scope,
    /// results, selection) survives the round trip through cleaning. Its
    /// closures capture value copies, not this environment, so caching it
    /// here creates no retain cycle.
    private(set) var duplicatesViewModel: DuplicatesViewModel?
    /// Set when cleaning was confirmed from the duplicate screen; its next
    /// appearance reconciles results against `lastCleanupReport`.
    private(set) var duplicatesNeedReconciliation = false

    init(
        preferences: PreferencesStore? = nil,
        scanEnvironment: ScanEnvironment = .live(),
        permissionProbe: PermissionProbe? = nil,
        loginItem: LoginItemController? = nil,
        fileRevealer: FileRevealer? = nil,
        folderPicker: FolderPicker? = nil,
        startupItems: StartupItemsController? = nil
    ) {
        // Fixture mode must not write the user's real preference domain —
        // scope defaults to a fixture-named suite there. An explicitly passed
        // store always wins.
        let defaults: UserDefaults
        if preferences != nil {
            defaults = .standard
        } else if ProcessInfo.processInfo.environment["CLEANORA_FIXTURE_HOME"] != nil {
            defaults = UserDefaults(suiteName: "com.cleanora.fixture") ?? .standard
        } else {
            defaults = .standard
        }
        self.preferences = preferences ?? PreferencesStore(defaults: defaults)
        self.scanEnvironment = scanEnvironment
        self.appDirectories = AppDirectories(environment: scanEnvironment)
        self.permissionProbe = permissionProbe ?? .live(environment: scanEnvironment)
        self.loginItem = loginItem ?? .live()
        self.fileRevealer = fileRevealer ?? .live()
        self.folderPicker = folderPicker ?? .live()
        self.startupItems = startupItems ?? .live()
    }

    // MARK: - Engines (the only construction sites in the app)

    /// Lazily created and cached; backed by Application Support.
    var scanHistoryStore: ScanHistoryStore {
        if let cachedHistoryStore { return cachedHistoryStore }
        let store = ScanHistoryStore(directory: appDirectories.applicationSupport)
        cachedHistoryStore = store
        return store
    }

    /// Stateless value type; rebuilt per scan because options vary. The
    /// catalog resolves the stored options first (developer gate → real
    /// scanner set), so the coordinator and the scanners see the same values.
    func scanCoordinator(options: ScanOptions) -> ScanCoordinator {
        let resolved = ScannerCatalog.resolvedOptions(options)
        return ScanCoordinator(
            scanners: ScannerCatalog.scanners(for: resolved, environment: scanEnvironment),
            environment: scanEnvironment,
            options: resolved,
            diskInfo: DiskInfoProvider()
        )
    }

    func cleanupExecutor() -> CleanupExecutor {
        CleanupExecutor(
            policy: .standard(home: scanEnvironment.home, tempRoot: scanEnvironment.temporaryRoot),
            logger: CleanupLogger(appDirs: appDirectories),
            environment: scanEnvironment,
            diskInfo: DiskInfoProvider()
        )
    }

    // MARK: - Permissions

    /// A method, not a property: probing touches the filesystem and must be
    /// an explicit call (the dashboard refresh), never a hidden read during
    /// body evaluation.
    func hasFullDiskAccess() -> Bool {
        permissionProbe.hasFullDiskAccess()
    }

    func openFullDiskAccessSettings() {
        permissionProbe.openFullDiskAccessSettings()
    }

    // MARK: - Flow transitions

    func finishScan(_ result: ScanResult) {
        lastScanResult = result
        // A new scan replaces the old review wholesale — any pending
        // cancelled-run reconciliation belongs to the previous result.
        resultsNeedReconciliation = false
        scanHistoryStore.saveLastScan(result)
    }

    /// Scan finish + P-13 auto-clean wiring. When "Automatically clean safe
    /// items" is on and the preselected set is safe to clean unattended, the
    /// cleanup starts without the confirmation sheet; every other path shows
    /// Results, and a skipped auto-clean says why.
    func scanDidFinish(_ result: ScanResult) {
        finishScan(result)
        let decision = CleaningFlowPolicy.autoCleanDecision(
            isEnabled: preferences.value.automaticallyCleanSafeItems,
            result: result
        )
        switch decision {
        case .beginImmediately(let items):
            autoCleanFallbackMessage = nil
            beginCleaning(Self.cleaningRequest(for: items, scanResultID: result.id))
            navigation.go(.cleaning)
        case .showResults(let fallbackReason):
            autoCleanFallbackMessage = fallbackReason
            navigation.go(.results)
        }
    }

    /// Single construction site for CleaningRequest on paths where the flow
    /// policy has already established that confirmation is not required.
    static func cleaningRequest(for items: [CleanupItem], scanResultID: UUID?) -> CleaningRequest {
        CleaningRequest(
            items: items,
            confirmed: Set(items.map(\.id)),
            destructiveConfirmed: false,
            selectedBytes: items.reduce(0) { $0 + $1.size },
            scanResultID: scanResultID
        )
    }

    /// Cancelled cleanup: the next Results appearance must re-derive its
    /// state, because items removed before the cancel still sit in the old
    /// view model with stale sizes.
    func markResultsStaleAfterCancelledCleanup() {
        resultsNeedReconciliation = true
    }

    /// Consumed exactly once, by ResultsView when it appears.
    func takeResultsReconciliation() -> Bool {
        let needed = resultsNeedReconciliation
        resultsNeedReconciliation = false
        return needed
    }

    // MARK: - Launch at login (P-15)

    /// Attempts the real registration and persists the preference only on
    /// success; a failure keeps the toggle at its persisted value and surfaces
    /// the ServiceManagement error as row status — loud, never silent.
    func setLaunchAtLogin(_ enabled: Bool) {
        let outcome = loginItem.setEnabled(enabled)
        switch outcome {
        case .succeeded:
            preferences.update { $0.launchAtLogin = enabled }
            loginItemStatusMessage = SettingsViewModel.launchAtLoginStatus(
                outcome: outcome, enabled: enabled
            )
        case .failed:
            loginItemStatusMessage = SettingsViewModel.launchAtLoginStatus(
                outcome: outcome, enabled: preferences.value.launchAtLogin
            )
        }
    }

    // MARK: - Main window (M-01)

    /// Opens (or recreates) the main window. The SwiftUI `openWindow` action
    /// only resolves inside a scene-hosted view, so CleanoraApp captures it
    /// here at launch; the menu bar popover — hosted outside any scene —
    /// calls through this seam instead. The AppKit fallback covers the window
    /// still existing (hidden/minimized).
    var openMainWindowHandler: (@MainActor () -> Void)?

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let openMainWindowHandler {
            openMainWindowHandler()
        } else if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Finder reveal (P-09)

    func revealInFinder(_ url: URL) {
        fileRevealer.reveal(url)
    }

    // MARK: - Duplicate finder (M-04)

    /// The single construction site for the duplicate-finder view model.
    func duplicatesFinder() -> DuplicatesViewModel {
        if let duplicatesViewModel { return duplicatesViewModel }
        let fresh = DuplicatesViewModel(environment: self)
        duplicatesViewModel = fresh
        return fresh
    }

    /// Called when a cleanup was confirmed from the duplicate screen.
    func markDuplicatesForReconciliation() {
        duplicatesNeedReconciliation = true
    }

    /// Consumed exactly once by the duplicate screen when it reappears after
    /// a cleaning run.
    func takeDuplicatesReconciliation() -> Bool {
        let needed = duplicatesNeedReconciliation
        duplicatesNeedReconciliation = false
        return needed
    }

    /// Runs the frozen DuplicateScanner contract over the user's opt-in
    /// scope. The scan environment is handed through so blocked subtrees are
    /// pruned even when the scope contains home. The only construction site;
    /// the view model injects this method and tests replace it wholesale.
    func findDuplicates(
        scope: [URL],
        options: DuplicateOptions,
        onProgress: @escaping @Sendable (_ filesExamined: Int, _ groupsFound: Int) -> Void
    ) async throws -> [DuplicateGroup] {
        try await DuplicateScanner().findDuplicates(
            in: scope,
            options: options,
            environment: scanEnvironment,
            onProgress: { progress in
                onProgress(progress.filesExamined, progress.duplicateGroupsFound)
            }
        )
    }

    func pickFolder() -> URL? {
        folderPicker.pickDirectory()
    }

    // MARK: - App uninstaller (M-06)

    /// The installed-app inventory; async so the view can load it off the
    /// first frame without blocking body evaluation.
    func appInventory() async throws -> [InstalledApp] {
        AppInventoryScanner().inventory(environment: scanEnvironment)
    }

    /// Planned related files for one app, straight from the planner — the UI
    /// never invents deletion targets.
    func plannedLeftovers(for app: InstalledApp) async throws -> [CleanupItem] {
        UninstallPlanner.plan(for: app, environment: scanEnvironment)
    }

    /// True when any running process carries this bundle identifier.
    func isBundleIDRunning(_ bundleID: String) -> Bool {
        !bundleID.isEmpty
            && !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: - Scheduled cleanup (M-07)

    /// The schedule loop, wired to this environment's engines. The closures
    /// are @Sendable, so `self` crosses the boundary inside an unsafe box —
    /// every access below hops back to the main actor, which is where all
    /// of AppEnvironment's mutable state lives anyway.
    private(set) var scheduler: CleanupScheduler?

    /// Starts or stops the loop to match the preference. Called from the
    /// Settings toggle and once at launch.
    func applySchedulePreference() {
        if preferences.value.scheduleEnabled {
            ensureScheduler().start()
        } else {
            scheduler?.stop()
        }
    }

    private func ensureScheduler() -> CleanupScheduler {
        if let scheduler { return scheduler }
        nonisolated(unsafe) let environment = self
        let fresh = CleanupScheduler(
            environment: scanEnvironment,
            preferences: preferences,
            history: scanHistoryStore,
            diskInfo: DiskInfoProvider(),
            scan: { options in
                await environment.performScan(options: options)
            },
            clean: { result in
                await environment.performScheduledClean(result)
            }
        )
        scheduler = fresh
        return fresh
    }

    /// One scheduled run, inline: full scan, then — only when the safe-only
    /// preference allows it — the preselected safe set through the normal
    /// executor. Never navigates and never shows a confirmation sheet: a
    /// background run that cannot clean safely just records what it found.
    /// The "Run now" button calls exactly this.
    ///
    /// This deliberately does NOT touch `lastScheduledRun`: the schedule slot
    /// is the loop's to stamp, and a manual run must not consume it (doing so
    /// would push the next fire back a full interval after a relaunch).
    func runScheduledCleanupNow() async {
        guard !isScheduledRunRunning else { return }
        isScheduledRunRunning = true
        defer { isScheduledRunRunning = false }

        guard let result = await performScan(options: preferences.value.scanOptions) else { return }
        finishScan(result)
        guard preferences.value.scheduleAutoCleanSafeOnly else { return }
        await performScheduledClean(result)
    }

    /// Runs one full scan to completion; nil when it failed or was cancelled.
    func performScan(options: ScanOptions) async -> ScanResult? {
        let coordinator = scanCoordinator(options: options)
        for await update in coordinator.run() {
            switch update {
            case .progress:
                continue
            case .finished(let result):
                return result
            case .failed:
                return nil
            }
        }
        return nil
    }

    /// The clean half of a scheduled run: exactly the selection the
    /// scheduler marked (safe, non-destructive) through the normal executor.
    /// Per the scheduler's contract, a run that freed nothing (everything
    /// gate-refused or already gone) is not worth a history entry.
    func performScheduledClean(_ result: ScanResult) async {
        let items = result.selectedItems
        guard !items.isEmpty else { return }
        let request = Self.cleaningRequest(for: items, scanResultID: result.id)
        for await event in cleanupExecutor().run(
            items: request.items,
            confirmed: request.confirmed,
            destructiveConfirmed: request.destructiveConfirmed
        ) {
            if case .finished(let report) = event, report.bytesFreed > 0 {
                finishCleanup(report)
            }
        }
    }

    /// Runs one cleanup to completion and records the report (history +
    /// reconciliation) exactly like the interactive path.
    func performCleanup(_ request: CleaningRequest) async {
        for await event in cleanupExecutor().run(
            items: request.items,
            confirmed: request.confirmed,
            destructiveConfirmed: request.destructiveConfirmed
        ) {
            if case .finished(let report) = event {
                finishCleanup(report)
            }
        }
    }

    func beginCleaning(_ request: CleaningRequest) {
        pendingCleaning = request
    }

    /// Consumed exactly once, by CleaningView, when the cleaning route opens.
    func takePendingCleaning() -> CleaningRequest? {
        let request = pendingCleaning
        pendingCleaning = nil
        return request
    }

    func finishCleanup(_ report: CleanupReport) {
        lastCleanupReport = report
        reconcileLastScan(after: report)
        guard preferences.value.keepCleanupHistory else { return }
        // A cleanup that validated everything out (or was cancelled before
        // the first item) has nothing worth remembering.
        guard !report.outcomes.isEmpty else { return }
        scanHistoryStore.appendHistory(
            CleanupHistoryEntry(from: report, appVersion: Self.appVersion)
        )
    }

    /// Drop items the cleanup actually removed from `lastScanResult`, so the
    /// dashboard totals and the disk chart stop counting deleted bytes after
    /// a partial (cancelled/refused) run — reviewer finding 2.
    private func reconcileLastScan(after report: CleanupReport) {
        guard var result = lastScanResult else { return }
        let removedPaths = Set(
            report.outcomes
                .filter { $0.status == .removed }
                .map(\.path)
        )
        guard !removedPaths.isEmpty else { return }
        let keptItems = result.items.filter { !removedPaths.contains($0.path.path) }
        guard keptItems.count != result.items.count else { return }
        result = ScanResult(
            id: result.id,
            startedAt: result.startedAt,
            finishedAt: result.finishedAt,
            items: keptItems,
            summaries: Self.summaries(for: keptItems),
            freeSpaceBefore: result.freeSpaceBefore,
            scannerKeys: result.scannerKeys
        )
        lastScanResult = result
        scanHistoryStore.saveLastScan(result)
    }

    private static func summaries(for items: [CleanupItem]) -> [CategorySummary] {
        ScanCategory.scanOrder.compactMap { category in
            let group = items.filter { $0.category == category }
            guard !group.isEmpty else { return nil }
            return CategorySummary(
                category: category,
                totalBytes: group.reduce(0) { $0 + $1.size },
                itemCount: group.count,
                preselectedBytes: group.filter(\.selected).reduce(0) { $0 + $1.size },
                reviewBytes: group.filter { !$0.selected }.reduce(0) { $0 + $1.size }
            )
        }
    }

    static let appVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }()
}
