import Foundation

/// Settings is bound directly to PreferencesStore in the view; this type
/// carries the small pieces of decision logic and copy so they stay pure and
/// testable.
struct SettingsViewModel {
    /// Scan-category toggle setter with a guard: the scan never runs with
    /// zero categories, so the last enabled category cannot be switched off.
    static func updatedCategories(
        current: Set<ScanCategory>,
        toggling category: ScanCategory,
        isOn: Bool
    ) -> Set<ScanCategory> {
        var updated = current
        if isOn {
            updated.insert(category)
        } else if updated.count > 1 {
            updated.remove(category)
        }
        return updated
    }

    // MARK: - Copy

    static let developerDataHint =
        "Adds Xcode, Homebrew, npm, pip, Yarn and Docker caches to the next scan."
    static let autoCleanHint =
        "After a scan, safe items are cleaned without asking. Review items always wait for you, and Trash is never touched automatically."
    static let confirmationHint =
        "When both confirmation settings are off, cleaning starts without a confirmation screen. Trash always asks."

    /// Settings-row status for the Launch at login toggle (P-15). Success
    /// states describe what was registered; a failure surfaces the
    /// ServiceManagement error verbatim — dev builds are unsigned, so the
    /// error is expected there and must be readable, never thrown away.
    static func launchAtLoginStatus(
        outcome: LoginItemController.Outcome,
        enabled: Bool
    ) -> String {
        switch outcome {
        case .succeeded:
            return enabled
                ? "Cleanora opens when you log in."
                : "Cleanora no longer opens at login."
        case .failed(let message):
            return "Couldn't update launch at login: \(message)"
        }
    }
}
