import Foundation
import ServiceManagement

/// Seam around SMAppService (P-15) so Settings logic is testable without
/// touching the real login-item database. App layer only — the ServiceManagement
/// import is banned in the engine layers.
struct LoginItemController: Sendable {
    enum Outcome: Equatable {
        case succeeded
        case failed(String)
    }

    var setEnabled: @MainActor @Sendable (Bool) -> Outcome
    var isCurrentlyEnabled: @MainActor @Sendable () -> Bool

    static func live() -> LoginItemController {
        LoginItemController(
            setEnabled: { enabled in
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
            isCurrentlyEnabled: { SMAppService.mainApp.status == .enabled }
        )
    }
}
