import AppKit
import Foundation
import Observation

/// What the UI needs to know about filesystem permissions, injected so the
/// dashboard and permission banner never talk to TCC directly. The default
/// probe is a lightweight listing canary; PermissionManager (Cleaning layer)
/// can replace it at integration time without touching a single view.
struct PermissionProbe: Sendable {
    var hasFullDiskAccess: @Sendable () -> Bool
    var openFullDiskAccessSettings: @MainActor @Sendable () -> Void

    static func live(environment: ScanEnvironment) -> PermissionProbe {
        PermissionProbe(
            hasFullDiskAccess: {
                // Canary: locations macOS gates behind Full Disk Access.
                // A readable listing means access; if neither canary exists
                // (fixture homes) we assume access since there is no gate.
                let fileManager = FileManager.default
                let candidates = [
                    environment.home.appendingPathComponent(
                        "Library/Application Support/MobileSync/Backup", isDirectory: true),
                    environment.home.appendingPathComponent("Library/Safari", isDirectory: true),
                ]
                for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
                    return (try? fileManager.contentsOfDirectory(atPath: candidate.path)) != nil
                }
                return true
            },
            openFullDiskAccessSettings: {
                guard let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                ) else { return }
                NSWorkspace.shared.open(url)
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
        preferences: PreferencesStore = PreferencesStore(),
        scanEnvironment: ScanEnvironment = .live(),
        permissionProbe: PermissionProbe? = nil
    ) {
        self.preferences = preferences
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
