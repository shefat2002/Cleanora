import SwiftUI

/// Minimal settings surface per spec: General / Scan / Cleaning.
/// Full binding work lands with the PreferencesStore-driven pass (U-12).
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var store = environment.preferences
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $store.preferences.launchAtLogin)
                Toggle("Show cleanup reminder", isOn: $store.preferences.showCleanupReminder)
                Toggle("Show confirmation before cleaning", isOn: $store.preferences.confirmBeforeCleaning)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
