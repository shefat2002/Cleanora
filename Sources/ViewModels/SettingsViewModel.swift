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

    static let launchAtLoginUnavailableHint = "Launch at login is coming in a later release."
    static let developerDataUnavailableHint =
        "Developer caches (Xcode, Homebrew, npm, pip, Yarn) arrive in a later release."
}
