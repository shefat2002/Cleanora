import Foundation
import ServiceManagement

/// One row of the Login Items screen (M-05). `isManagedByCleanora` marks the
/// only items this process may register/unregister — ServiceManagement only
/// lets an app control items declared in its own bundle, so foreign rows are
/// information-only and route to System Settings.
struct StartupItem: Identifiable, Equatable, Sendable {
    /// Bundle identifier (own login item) or plist name (agents/daemons).
    let identifier: String
    let displayName: String
    /// "Login item" / "Launch agent" / "Launch daemon".
    let kindLabel: String
    let isManagedByCleanora: Bool
    let isEnabled: Bool
    var id: String { identifier }
}

enum StartupItemOutcome: Equatable {
    case succeeded
    case failed(String)
}

/// Seam around SMAppService (M-05) so the Login Items screen is testable
/// without touching the real login-item database. App layer only — the
/// ServiceManagement import is banned in the engine layers.
///
/// macOS 13/14 exposes NO enumeration API for other apps' login items
/// (`SMAppService` can only construct services from this bundle's own
/// identifiers/plists), so `live()` lists exactly what is honestly knowable:
/// Cleanora's own login item. Everything else is a System Settings deep link.
struct StartupItemsController: Sendable {
    var list: @MainActor @Sendable () -> [StartupItem]
    var setEnabled: @MainActor @Sendable (StartupItem, Bool) -> StartupItemOutcome
    var openSystemSettings: @MainActor @Sendable () -> Void

    /// Deep link into System Settings → General → Login Items.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func live(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.cleanora.app") -> StartupItemsController {
        StartupItemsController(
            list: {
                let service = SMAppService.mainApp
                let status = service.status
                return [
                    StartupItem(
                        identifier: bundleIdentifier,
                        displayName: "Cleanora",
                        kindLabel: "Login item",
                        isManagedByCleanora: true,
                        // "Requires approval" means the user asked for it and
                        // the system is waiting — report it as on, with a
                        // note, not as off.
                        isEnabled: status == .enabled || status == .requiresApproval
                    )
                ]
            },
            setEnabled: { _, enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    return .succeeded
                } catch {
                    return .failed(error.localizedDescription)
                }
            },
            openSystemSettings: {
                Self.openLoginItemsSettings()
            }
        )
    }
}
