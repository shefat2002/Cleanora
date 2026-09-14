import Foundation
import Observation

/// Login Items screen state (M-05). macOS exposes no API to enumerate other
/// apps' login items, so the list is whatever the injected controller can
/// honestly report (Cleanora's own item) plus copy that routes everything
/// else to System Settings.
@MainActor
@Observable
final class StartupItemsViewModel {
    struct Row: Identifiable, Equatable {
        let item: StartupItem
        /// Only Cleanora's own item is togglable — ServiceManagement refuses
        /// to manage foreign items, so those rows are information-only.
        let isToggleEnabled: Bool
        let statusLine: String
        var id: String { item.id }
    }

    private(set) var rows: [Row] = []
    private(set) var didLoad = false

    private let controller: StartupItemsController

    init(controller: StartupItemsController) {
        self.controller = controller
    }

    convenience init(environment: AppEnvironment) {
        self.init(controller: environment.startupItems)
    }

    func refresh() {
        rows = Self.rows(for: controller.list())
        didLoad = true
    }

    // MARK: - Pure logic

    nonisolated static func rows(for items: [StartupItem]) -> [Row] {
        items.map { item in
            Row(
                item: item,
                isToggleEnabled: item.isManagedByCleanora,
                statusLine: statusLine(for: item)
            )
        }
    }

    nonisolated static func statusLine(for item: StartupItem) -> String {
        if item.isManagedByCleanora {
            return item.isEnabled ? "On" : "Off"
        }
        return item.isEnabled
            ? "On — managed in System Settings"
            : "Managed in System Settings"
    }

    static let foreignItemsHint =
        "Login items other apps added can't be changed from here. " +
            "System Settings → General → Login Items lists them all."
}
