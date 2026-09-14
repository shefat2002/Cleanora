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

    /// Bundle IDs currently running, refreshed when an app is selected.
    private(set) var runningBundleIDs: Set<String> = []

    var searchText = "" {
        didSet { filteredApps = Self.filteredApps(apps, matching: searchText) }
    }

    var isEmpty: Bool { apps.isEmpty && !isLoadingInventory }
    var isAppRunning: Bool {
        guard let bundleID = selectedApp?.bundleID, !bundleID.isEmpty else { return false }
        return runningBundleIDs.contains(bundleID)
    }
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
    private let isBundleIDRunning: @MainActor (String) -> Bool

    init(
        loadInventory: @escaping @MainActor () async throws -> [InstalledApp],
        planLeftovers: @escaping @MainActor (InstalledApp) async throws -> [CleanupItem],
        isBundleIDRunning: @escaping @MainActor (String) -> Bool
    ) {
        self.loadInventory = loadInventory
        self.planLeftovers = planLeftovers
        self.isBundleIDRunning = isBundleIDRunning
    }

    convenience init(environment: AppEnvironment) {
        self.init(
            loadInventory: { try await environment.appInventory() },
            planLeftovers: { app in
                try await environment.plannedLeftovers(for: app)
            },
            isBundleIDRunning: { environment.isBundleIDRunning($0) }
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
            inventoryError = error.localizedDescription
        }
    }

    func select(_ app: InstalledApp) {
        guard selectedApp != app else { return }
        selectedApp = app
        leftovers = []
        if let bundleID = app.bundleID, !bundleID.isEmpty, isBundleIDRunning(bundleID) {
            runningBundleIDs = [bundleID]
        } else {
            runningBundleIDs = []
        }
        // Third-party leftovers are review rows; nothing is ever preselected,
        // no matter what the planner produced.
        isLoadingLeftovers = true
        Task { [weak self] in
            guard let self else { return }
            do {
                self.leftovers = Self.unchecked(try await self.planLeftovers(app))
                self.inventoryError = nil
            } catch {
                self.inventoryError = error.localizedDescription
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
