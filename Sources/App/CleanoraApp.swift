import SwiftUI

@main
struct CleanoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()
    @State private var menuBarController = MenuBarController()

    // body is split into builder properties: the scenes + modifiers in one
    // expression exceeded the type checker's budget. The menu bar item is
    // NOT a scene — SceneBuilder's buildIf + MenuBarExtra crashes this
    // toolchain's type checker, so MenuBarController (NSStatusItem + popover)
    // owns its appearance instead.
    var body: some Scene {
        mainScene
        settingsScene
    }

    private var mainScene: some Scene {
        WindowGroup(id: MenuBarPanelView.mainWindowID) {
            mainWindowContent
        }
        .windowResizability(.contentMinSize)
    }

    private var mainWindowContent: some View {
        RootView()
            .environment(environment)
            .frame(minWidth: 720, minHeight: 520)
            .frame(width: 900, height: 620)
            .task {
                syncMenuBarState()
                environment.applySchedulePreference()
            }
            .onChange(of: environment.preferences.value.menuBarEnabled) { _, _ in
                syncMenuBarState()
            }
    }

    private var settingsScene: some Scene {
        Settings {
            SettingsView()
                .environment(environment)
        }
    }

    /// Closing the main window must not quit the app while the menu bar item
    /// is alive; the delegate re-checks on every window close.
    private func syncMenuBarState() {
        appDelegate.isMenuBarEnabled = environment.preferences.value.menuBarEnabled
        menuBarController.activateMainWindow = {
            NSApp.activate(ignoringOtherApps: true)
        }
        menuBarController.update(
            enabled: environment.preferences.value.menuBarEnabled,
            environment: environment
        )
    }
}

/// The menu bar panel's content, extracted so heavy views stay out of the
/// scene builder's type-checking budget.
private struct MenuBarSceneContent: View {
    let environment: AppEnvironment

    var body: some View {
        MenuBarPanelView()
            .environment(environment)
    }
}
