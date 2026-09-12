import SwiftUI

/// Spec §11: three minimal sections — General, Scan, Cleaning — bound
/// straight to PreferencesStore so every change persists immediately.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var store = environment.preferences
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $store.preferences.launchAtLogin)
                    .disabled(true)
                    .accessibilityHint(SettingsViewModel.launchAtLoginUnavailableHint)
                Text(SettingsViewModel.launchAtLoginUnavailableHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show cleanup reminder", isOn: $store.preferences.showCleanupReminder)
                Toggle("Show confirmation before cleaning", isOn: $store.preferences.confirmBeforeCleaning)
            }

            Section("Scan") {
                ForEach(ScanCategory.phaseOne) { category in
                    Toggle(category.displayName, isOn: categoryBinding(category))
                }
                Toggle("Developer caches", isOn: $store.preferences.includeDeveloperData)
                Text(SettingsViewModel.developerDataUnavailableHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cleaning") {
                Toggle("Ask before deleting", isOn: $store.preferences.askBeforeDeleting)
                Toggle("Automatically clean safe items", isOn: $store.preferences.automaticallyCleanSafeItems)
                Toggle("Keep cleanup history", isOn: $store.preferences.keepCleanupHistory)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    /// Scan categories live in a Set; this binding goes through
    /// SettingsViewModel so the last enabled category can't be switched off.
    private func categoryBinding(_ category: ScanCategory) -> Binding<Bool> {
        Binding(
            get: {
                environment.preferences.value.enabledCategories.contains(category)
            },
            set: { isOn in
                environment.preferences.update {
                    $0.enabledCategories = SettingsViewModel.updatedCategories(
                        current: $0.enabledCategories,
                        toggling: category,
                        isOn: isOn
                    )
                }
            }
        )
    }
}
