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

    private let appDirectories: AppDirectories
    private let permissionProbe: PermissionProbe
    private let loginItem: LoginItemController
    private let fileRevealer: FileRevealer
    private var cachedHistoryStore: ScanHistoryStore?

    init(
        preferences: PreferencesStore? = nil,
        scanEnvironment: ScanEnvironment = .live(),
        permissionProbe: PermissionProbe? = nil,
        loginItem: LoginItemController? = nil,
        fileRevealer: FileRevealer? = nil
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

    // MARK: - Finder reveal (P-09)

    func revealInFinder(_ url: URL) {
        fileRevealer.reveal(url)
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
        guard preferences.value.keepCleanupHistory else { return }
        // A cleanup that validated everything out (or was cancelled before
        // the first item) has nothing worth remembering.
        guard !report.outcomes.isEmpty else { return }
        scanHistoryStore.appendHistory(
            CleanupHistoryEntry(from: report, appVersion: Self.appVersion)
        )
    }

    static let appVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }()
}
