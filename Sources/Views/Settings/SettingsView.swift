import SwiftUI

/// Spec §11: three minimal sections — General, Scan, Cleaning — bound
/// straight to PreferencesStore so every change persists immediately.
/// P-13/P-15: the toggles are all live now. Launch at login goes through
/// AppEnvironment (SMAppService), the developer toggle feeds the real
/// scanner set via ScannerCatalog, and the confirmation/auto-clean toggles
/// drive CleaningFlowPolicy.
///
/// Phase 3 (M-01/M-05/M-07): menu bar toggle, the Scheduler section
/// (interval picker, safe-only note, last/next run, Run now), the Login
/// Items section, and links to the new tools.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var startupItemsViewModel: StartupItemsViewModel?
    @State private var isRunningScheduledCleanup = false

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
                Toggle("Show in menu bar", isOn: $store.preferences.menuBarEnabled)
                Text("Keeps Cleanora in the menu bar when the main window is closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Menu bar hint: keeps Cleanora in the menu bar when the main window is closed.")
                Toggle("Show cleanup reminder", isOn: $store.preferences.showCleanupReminder)
                Toggle("Show confirmation before cleaning", isOn: $store.preferences.confirmBeforeCleaning)
            }

            schedulerSection

            loginItemsSection

            Section("Scan") {
                ForEach(ScanCategory.phaseOne) { category in
                    Toggle(category.displayName, isOn: categoryBinding(category))
                }
                Toggle("Developer caches", isOn: $store.preferences.includeDeveloperData)
                Text(SettingsViewModel.developerDataHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            toolsSection

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
        .onChange(of: environment.preferences.value.scheduleEnabled) { _, _ in
            environment.applySchedulePreference()
        }
        .task {
            if startupItemsViewModel == nil {
                startupItemsViewModel = StartupItemsViewModel(environment: environment)
            }
            startupItemsViewModel?.refresh()
        }
    }

    // MARK: - Scheduler (M-07)

    private var schedulerSection: some View {
        @Bindable var store = environment.preferences
        return Section("Scheduled Cleanup") {
            Toggle("Scan on a schedule", isOn: $store.preferences.scheduleEnabled)
            Picker("Every", selection: intervalBinding) {
                ForEach(SchedulerSettingsViewModel.intervalChoices, id: \.self) { days in
                    Text(SchedulerSettingsViewModel.intervalLabel(for: days))
                        .tag(days)
                }
            }
            .disabled(!environment.preferences.value.scheduleEnabled)
            Toggle(
                "Clean safe items automatically",
                isOn: $store.preferences.scheduleAutoCleanSafeOnly
            )
            .disabled(!environment.preferences.value.scheduleEnabled)
            Text(SchedulerSettingsViewModel.safeOnlyHint)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let lastRunLine = SchedulerSettingsViewModel.lastRunLine(
                for: environment.preferences.value.lastScheduledRun
            ) {
                Text(lastRunLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(lastRunLine)
            }
            if let nextRunLine = SchedulerSettingsViewModel.nextRunLine(
                scheduleEnabled: environment.preferences.value.scheduleEnabled,
                lastRun: environment.preferences.value.lastScheduledRun,
                intervalDays: environment.preferences.value.clampedScheduleIntervalDays,
                now: Date()
            ) {
                Text(nextRunLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(nextRunLine)
            }

            Button {
                runScheduledCleanupNow()
            } label: {
                Label(
                    SchedulerSettingsViewModel.runNowTitle(isRunning: isRunningScheduledCleanup),
                    systemImage: "play.circle"
                )
            }
            .disabled(isRunningScheduledCleanup)
            .accessibilityHint(SchedulerSettingsViewModel.runNowHint)
        }
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { environment.preferences.value.clampedScheduleIntervalDays },
            set: { pickerValue in
                environment.preferences.update {
                    $0.scheduleIntervalDays = SchedulerSettingsViewModel.sanitizedInterval(
                        pickerValue: pickerValue,
                        current: $0.scheduleIntervalDays
                    )
                }
            }
        )
    }

    private func runScheduledCleanupNow() {
        guard !isRunningScheduledCleanup else { return }
        isRunningScheduledCleanup = true
        Task {
            await environment.runScheduledCleanupNow()
            isRunningScheduledCleanup = false
        }
    }

    // MARK: - Login Items (M-05)

    private var loginItemsSection: some View {
        Section("Login Items") {
            if let startupItemsViewModel {
                ForEach(startupItemsViewModel.rows) { row in
                    HStack {
                        Toggle(row.item.displayName, isOn: startupItemBinding(row))
                            .disabled(!row.isToggleEnabled)
                        Spacer()
                        Text(row.statusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(row.item.displayName) status: \(row.statusLine)")
                    }
                }
            }
            Text(StartupItemsViewModel.foreignItemsHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                environment.startupItems.openSystemSettings()
            } label: {
                Label("Open System Settings", systemImage: "gearshape")
            }
            .accessibilityHint("Opens System Settings → General → Login Items.")
        }
    }

    /// Cleanora's own item shares the Launch at login path (one service, one
    /// source of truth). Foreign rows never become togglable.
    private func startupItemBinding(_ row: StartupItemsViewModel.Row) -> Binding<Bool> {
        Binding(
            get: {
                row.item.isManagedByCleanora
                    ? environment.preferences.value.launchAtLogin
                    : row.item.isEnabled
            },
            set: { isOn in
                if row.item.isManagedByCleanora {
                    environment.setLaunchAtLogin(isOn)
                }
            }
        )
    }

    // MARK: - Tools

    private var toolsSection: some View {
        Section("Tools") {
            Button {
                environment.navigation.go(.duplicates)
            } label: {
                Label("Duplicate Finder", systemImage: "doc.on.doc")
            }
            .accessibilityHint("Searches folders you choose for duplicate files.")

            Button {
                environment.navigation.go(.uninstaller)
            } label: {
                Label("Uninstaller", systemImage: "minus.app")
            }
            .accessibilityHint("Lists installed apps and their leftover files.")

            Button {
                environment.navigation.go(.developer)
            } label: {
                Label("Developer Cleanup", systemImage: "hammer")
            }
            .accessibilityHint("Shows the developer caches from the last scan.")
        }
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
