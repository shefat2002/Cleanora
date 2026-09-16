import Foundation
import Observation

/// Owns the app uninstaller screen (M-06): the installed-app inventory, the
/// search filter, the selected app's planned leftovers (all unselected —
/// review only), and the running-app gate that disables Uninstall while the
/// app is open.
///
/// The running check is an injected seam so tests never touch
/// NSRunningApplication; refusal messages from the safety gate (Containers)
/// surface through the normal cleanup outcome display.
@MainActor
@Observable
final class UninstallerViewModel {
    private(set) var apps: [InstalledApp] = []
    private(set) var isLoadingInventory = false
    private(set) var inventoryError: String?

    private(set) var filteredApps: [InstalledApp] = []

    private(set) var selectedApp: InstalledApp?
    private(set) var leftovers: [CleanupItem] = []
    private(set) var isLoadingLeftovers = false

    /// Failure from planning the selected app's leftovers. Deliberately
    /// separate from `inventoryError`: a failed plan is not an inventory
    /// problem, and the detail pane must show it instead of falling through
    /// to the "No related files found" empty state.
    private(set) var leftoversError: String?

    /// Running-gate result for the selected app. Refreshed on select AND on
    /// every uninstall attempt (reviewer finding: a select-time snapshot goes
    /// stale — launch the app after selecting, and the old gate would trash
    /// a running bundle).
    private(set) var selectedAppRunning = false

    var searchText = "" {
        didSet { filteredApps = Self.filteredApps(apps, matching: searchText) }
    }

    var isEmpty: Bool { apps.isEmpty && !isLoadingInventory }
    var isAppRunning: Bool { selectedAppRunning }
    var uninstallDisabledReason: String? {
        guard selectedApp != nil else { return nil }
        guard !isAppRunning else { return "Quit \(selectedApp?.name ?? "the app") first" }
        return nil
    }

    var selectedItems: [CleanupItem] { leftovers.filter(\.selected) }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var selectedCount: Int { selectedItems.count }
    var requiresDestructiveConfirmation: Bool {
        selectedItems.contains(where: CleaningFlowPolicy.isDestructive)
    }
    var sourceScanID: UUID { sessionID }
    var canUninstall: Bool { selectedApp != nil && !isAppRunning && selectedCount > 0 }

    private let sessionID = UUID()
    private let loadInventory: @MainActor () async throws -> [InstalledApp]
    private let planLeftovers: @MainActor (InstalledApp) async throws -> [CleanupItem]
    /// Fresh probe per call — never a cached snapshot.
    private let isAppRunningProbe: @MainActor (InstalledApp) -> Bool

    init(
        loadInventory: @escaping @MainActor () async throws -> [InstalledApp],
        planLeftovers: @escaping @MainActor (InstalledApp) async throws -> [CleanupItem],
        isAppRunning: @escaping @MainActor (InstalledApp) -> Bool
    ) {
        self.loadInventory = loadInventory
        self.planLeftovers = planLeftovers
        self.isAppRunningProbe = isAppRunning
    }

    convenience init(environment: AppEnvironment) {
        self.init(
            loadInventory: { try await environment.appInventory() },
            planLeftovers: { app in
                try await environment.plannedLeftovers(for: app)
            },
            isAppRunning: { environment.isAppRunning($0) }
        )
    }

    // MARK: - Loading

    func loadInventoryIfNeeded() async {
        guard apps.isEmpty, !isLoadingInventory else { return }
        isLoadingInventory = true
        defer { isLoadingInventory = false }
        do {
            apps = Self.sortedApps(try await loadInventory())
            filteredApps = apps
            inventoryError = nil
        } catch {
            inventoryError = Self.inventoryFailureMessage(for: error)
        }
    }

    func select(_ app: InstalledApp) {
        guard selectedApp != app else { return }
        selectedApp = app
        leftovers = []
        revalidateRunningGate()
        // Third-party leftovers are review rows; nothing is ever preselected,
        // no matter what the planner produced.
        isLoadingLeftovers = true
        Task { [weak self] in
            guard let self else { return }
            do {
                self.leftovers = Self.unchecked(try await self.planLeftovers(app))
                self.leftoversError = nil
            } catch {
                // `leftovers` stays empty from the synchronous clear above, so
                // a failed plan can never enable Uninstall.
                self.leftoversError = Self.leftoversFailureMessage(for: app, error: error)
            }
            self.isLoadingLeftovers = false
        }
    }

    // MARK: - Selection

    func setSelection(_ isSelected: Bool, itemID: UUID) {
        for index in leftovers.indices where leftovers[index].id == itemID {
            leftovers[index].selected = isSelected
        }
    }

    /// Fresh running-app probe for the selected app. The View calls this at
    /// every uninstall attempt — selecting an app and THEN launching it must
    /// still be caught (M-06 spec: refuse if the app is running).
    func revalidateRunningGate() {
        guard let app = selectedApp else {
            selectedAppRunning = false
            return
        }
        selectedAppRunning = isAppRunningProbe(app)
    }

    /// The View must call this before building a CleaningRequest; a false
    /// return means the running gate just flipped (reason text is live).
    func uninstallAllowedAfterRevalidation() -> Bool {
        revalidateRunningGate()
        return canUninstall
    }

    // MARK: - Pure logic

    nonisolated static func sortedApps(_ apps: [InstalledApp]) -> [InstalledApp] {
        apps.sorted {
            if $0.name.caseInsensitiveCompare($1.name) != .orderedSame {
                return $0.name.caseInsensitiveCompare($1.name) == .orderedAscending
            }
            return ($0.bundleID ?? "") < ($1.bundleID ?? "")
        }
    }

    /// Case-insensitive match on name or bundle ID; an empty query lists all.
    nonisolated static func filteredApps(
        _ apps: [InstalledApp],
        matching query: String
    ) -> [InstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter {
            $0.name.range(of: trimmed, options: .caseInsensitive) != nil
                || ($0.bundleID ?? "").range(of: trimmed, options: .caseInsensitive) != nil
        }
    }

    /// Inventory failures are shaped for people, never raw error strings: a
    /// permission problem says what fixes it; anything else says what happened
    /// and that nothing was touched.
    nonisolated static func inventoryFailureMessage(for error: Error) -> String {
        let permissionDenied =
            (error as? CocoaError)?.code == .fileReadNoPermission
            || (error as? POSIXError)?.code == .EACCES
        if permissionDenied {
            return "Cleanora couldn't read your applications folder. Grant Full Disk Access in System Settings, then try again."
        }
        return "Cleanora couldn't read your applications folder. Nothing was changed — try again."
    }

    /// A failed plan must not read as "No related files found": name the app
    /// and state plainly that nothing was changed. The error itself is kept in
    /// the signature for future detail; the user copy stays factual either way.
    nonisolated static func leftoversFailureMessage(
        for app: InstalledApp,
        error: Error
    ) -> String {
        "Cleanora couldn't check \(app.name)'s related files. Nothing was changed — try selecting it again."
    }

    /// Defense in depth: the planner promises review rows that start
    /// unchecked; the UI boundary re-applies it so a planner change can never
    /// preselect deletions.
    nonisolated static func unchecked(_ items: [CleanupItem]) -> [CleanupItem] {
        items.map { $0.withSelection(false) }
    }

    /// "Version 2.1" line; nil when the bundle carries no version.
    nonisolated static func versionLine(for app: InstalledApp) -> String? {
        guard let version = app.version, !version.isEmpty else { return nil }
        return "Version \(version)"
    }
}

extension UninstallerViewModel: CleaningSelectionProviding {}
