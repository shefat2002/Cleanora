import SwiftUI

/// Spec §11: three minimal sections — General, Scan, Cleaning — bound
/// straight to PreferencesStore so every change persists immediately.
/// P-13/P-15: the toggles are all live now. Launch at login goes through
/// AppEnvironment (SMAppService), the developer toggle feeds the real
/// scanner set via ScannerCatalog, and the confirmation/auto-clean toggles
/// drive CleaningFlowPolicy.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var store = environment.preferences
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                if let status = environment.loginItemStatusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Launch at login status: \(status)")
                }
                Toggle("Show cleanup reminder", isOn: $store.preferences.showCleanupReminder)
                Toggle("Show confirmation before cleaning", isOn: $store.preferences.confirmBeforeCleaning)
            }

            Section("Scan") {
                ForEach(ScanCategory.phaseOne) { category in
                    Toggle(category.displayName, isOn: categoryBinding(category))
                }
                Toggle("Developer caches", isOn: $store.preferences.includeDeveloperData)
                Text(SettingsViewModel.developerDataHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    environment.navigation.go(.developer)
                } label: {
                    Label("Developer Cleanup", systemImage: "hammer")
                }
                .accessibilityHint("Shows the developer caches from the last scan.")
            }

            Section("Cleaning") {
                Toggle("Ask before deleting", isOn: $store.preferences.askBeforeDeleting)
                Toggle("Automatically clean safe items", isOn: $store.preferences.automaticallyCleanSafeItems)
                Text(SettingsViewModel.autoCleanHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Keep cleanup history", isOn: $store.preferences.keepCleanupHistory)
                Text(SettingsViewModel.confirmationHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    /// Not a direct store binding: the ServiceManagement call decides whether
    /// the preference changes. On failure the toggle snaps back to its
    /// persisted value and the row's status text explains why.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { environment.preferences.value.launchAtLogin },
            set: { environment.setLaunchAtLogin($0) }
        )
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
