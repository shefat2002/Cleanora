import AppKit
import SwiftUI

/// App uninstaller (M-06): installed-app inventory on the left, the selected
/// app's planned leftovers on the right — all unselected, review-only. The
/// Uninstall button is disabled while the app is running; items the safety
/// gate refuses (Containers) surface through the normal outcome display.
struct UninstallerView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: UninstallerViewModel?
    @State private var confirmSheetVisible = false

    var body: some View {
        Group {
            if let viewModel {
                if viewModel.inventoryError != nil && viewModel.apps.isEmpty {
                    VStack(spacing: 0) {
                        header
                        Divider()
                        EmptyStateView(
                            systemImage: "exclamationmark.triangle",
                            title: "Couldn't read installed apps",
                            message: viewModel.inventoryError ?? "Unknown error."
                        )
                    }
                } else {
                    content(viewModel)
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if viewModel == nil {
                let fresh = UninstallerViewModel(environment: environment)
                viewModel = fresh
            }
            await viewModel?.loadInventoryIfNeeded()
        }
        .sheet(isPresented: $confirmSheetVisible) {
            if let viewModel {
                ConfirmCleanSheet(selection: viewModel) { request in
                    // Re-probe: the sheet may have been open while the app
                    // was launched. A flipped gate aborts the request.
                    guard viewModel.uninstallAllowedAfterRevalidation() else {
                        confirmSheetVisible = false
                        return
                    }
                    environment.beginCleaning(request)
                    environment.navigation.go(.cleaning)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: Design.spacingXS) {
            HStack {
                Button {
                    environment.navigation.go(.dashboard)
                } label: {
                    Label("Dashboard", systemImage: "chevron.left")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back to dashboard")
                Spacer()
            }
            .padding(.horizontal, Design.spacingL)
            Text("Uninstaller")
                .font(.title2.weight(.bold))
            Text("Every file stays until you review it — related caches and support files are listed per app, and running apps can't be removed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Design.spacingL)
                .padding(.bottom, Design.spacingM)
        }
        .accessibilityElement(children: .contain)
    }

    private func content(_ viewModel: UninstallerViewModel) -> some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.isLoadingInventory && viewModel.apps.isEmpty {
                ProgressView("Reading installed apps…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    appList(viewModel)
                        .frame(width: 280)
                    Divider()
                    detailPane(viewModel)
                }
                Divider()
                SelectionSummaryBar(
                    title: "Uninstall",
                    selectedBytes: viewModel.selectedBytes,
                    selectedCount: viewModel.selectedCount,
                    canClean: viewModel.canUninstall
                ) {
                    uninstall(viewModel)
                }
            }
        }
    }

    // MARK: - App list

    private func appList(_ viewModel: UninstallerViewModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search apps", text: Binding(
                    get: { viewModel.searchText },
                    set: { viewModel.searchText = $0 }
                ))
                .textFieldStyle(.plain)
                .accessibilityLabel("Search installed apps")
            }
            .padding(Design.spacingS)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .padding(Design.spacingM)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredApps, id: \.url) { app in
                        appRow(viewModel, app: app)
                        Divider().opacity(0.4)
                    }
                    if viewModel.filteredApps.isEmpty {
                        Text("No apps match “\(viewModel.searchText)”.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(Design.spacingL)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func appRow(
        _ viewModel: UninstallerViewModel,
        app: InstalledApp
    ) -> some View {
        let isSelected = viewModel.selectedApp?.bundleID == app.bundleID
        return Button {
            viewModel.select(app)
        } label: {
            HStack(spacing: Design.spacingS) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.callout)
                        .lineLimit(1)
                    Text("\(app.bundleSize.formattedByteCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Design.spacingS)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(app.name), \(app.bundleSize.formattedByteCount)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Shows the files Cleanora would remove for this app.")
    }

    // MARK: - Detail

    @ViewBuilder
    private func detailPane(_ viewModel: UninstallerViewModel) -> some View {
        if let app = viewModel.selectedApp {
            detail(viewModel, app: app)
        } else {
            EmptyStateView(
                systemImage: "minus.app",
                title: "Select an app",
                message: "Choose an app on the left to see what would be removed with it."
            )
        }
    }

    private func detail(_ viewModel: UninstallerViewModel, app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: Design.spacingM) {
            HStack(spacing: Design.spacingM) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.title3.weight(.semibold))
                    if let versionLine = UninstallerViewModel.versionLine(for: app) {
                        Text(versionLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(app.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(app.url.path)
                }
                Spacer(minLength: Design.spacingS)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(app.bundleSize.formattedByteCount)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text("app bundle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            if viewModel.isAppRunning {
                Label(UninstallerViewModel.runningWarning(for: app), systemImage: "exclamationmark.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(Design.spacingS)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.orange.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: Design.cornerRadius)
                    )
                    .accessibilityElement(children: .combine)
            }

            leftoversList(viewModel)
        }
        .padding(Design.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func leftoversList(_ viewModel: UninstallerViewModel) -> some View {
        VStack(alignment: .leading, spacing: Design.spacingS) {
            Text("Would be removed with \(viewModel.selectedApp?.name ?? "this app")")
                .font(.headline)
            Text("Nothing is selected automatically. Review each row first.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Stated as fact, up front, without pre-labeling rows: the safety
            // gate owns the refusal and says so per item after a clean.
            Text("App Containers and preference plists are protected — Cleanora lists them, but the safety gate will refuse to remove them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.isLoadingLeftovers {
                ProgressView()
                    .padding(.top, Design.spacingS)
            } else if viewModel.leftovers.isEmpty {
                Text("No related files found — removing the app bundle is all there is to it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, Design.spacingS)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.leftovers) { item in
                            leftoverRow(viewModel, item: item)
                            Divider().opacity(0.3)
                        }
                    }
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: Design.cornerRadius)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Design.cornerRadius)
                            .strokeBorder(.quaternary)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func leftoverRow(
        _ viewModel: UninstallerViewModel,
        item: CleanupItem
    ) -> some View {
        HStack(spacing: Design.spacingM) {
            Toggle(isOn: Binding(
                get: { item.selected },
                set: { viewModel.setSelection($0, itemID: item.id) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("\(item.selected ? "Deselect" : "Select") \(item.name)")
            .accessibilityHint(item.reason)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.path.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path.path)
            }
            Spacer(minLength: Design.spacingS)
            Text(item.size.formattedByteCount)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, Design.spacingM)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    /// Same confirmation gate as Results and Developer Cleanup. The running
    /// gate is re-probed on every attempt AND again when the sheet confirms —
    /// the app may have been launched between selection and this click.
    private func uninstall(_ viewModel: UninstallerViewModel) {
        guard viewModel.uninstallAllowedAfterRevalidation() else { return }
        if CleaningFlowPolicy.requiresConfirmation(
            confirmBeforeCleaning: environment.preferences.value.confirmBeforeCleaning,
            askBeforeDeleting: environment.preferences.value.askBeforeDeleting,
            items: viewModel.selectedItems
        ) {
            confirmSheetVisible = true
        } else {
            guard viewModel.uninstallAllowedAfterRevalidation() else { return }
            environment.beginCleaning(AppEnvironment.cleaningRequest(
                for: viewModel.selectedItems,
                scanResultID: viewModel.sourceScanID
            ))
            environment.navigation.go(.cleaning)
        }
    }
}

private extension UninstallerViewModel {
    /// Row copy for the running-app gate; factual, no scare copy.
    nonisolated static func runningWarning(for app: InstalledApp) -> String {
        "\(app.name) is open. Quit it first — Cleanora won't remove files from a running app."
    }
}
