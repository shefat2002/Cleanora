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

    private let appDirectories: AppDirectories
    private let permissionProbe: PermissionProbe
    private var cachedHistoryStore: ScanHistoryStore?

    init(
        preferences: PreferencesStore? = nil,
        scanEnvironment: ScanEnvironment = .live(),
        permissionProbe: PermissionProbe? = nil
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
    }

    // MARK: - Engines (the only construction sites in the app)

    /// Lazily created and cached; backed by Application Support.
    var scanHistoryStore: ScanHistoryStore {
        if let cachedHistoryStore { return cachedHistoryStore }
        let store = ScanHistoryStore(directory: appDirectories.applicationSupport)
        cachedHistoryStore = store
        return store
    }

    /// Stateless value type; rebuilt per scan because options vary.
    func scanCoordinator(options: ScanOptions) -> ScanCoordinator {
        ScanCoordinator(
            scanners: ScannerCatalog.scanners(for: options, environment: scanEnvironment),
            environment: scanEnvironment,
            options: options,
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
        scanHistoryStore.saveLastScan(result)
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
