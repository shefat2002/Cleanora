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
            MainSceneRoot(appDelegate: appDelegate, menuBarController: menuBarController)
                .environment(environment)
                .frame(minWidth: 720, minHeight: 520)
                .frame(width: 900, height: 620)
        }
        .windowResizability(.contentMinSize)
    }

    private var settingsScene: some Scene {
        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}

/// WindowGroup content (a real View, so `openWindow` resolves here): hands
/// the environment to the app delegate and the menu bar controller, captures
/// the window-opening action for scene-less surfaces (the popover), and
/// starts the schedule loop when the preference asks for it.
private struct MainSceneRoot: View {
    let appDelegate: AppDelegate
    let menuBarController: MenuBarController
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openMainWindow

    var body: some View {
        RootView()
            .task {
                environment.openMainWindowHandler = {
                    openMainWindow(id: MenuBarPanelView.mainWindowID)
                }
                appDelegate.isMenuBarEnabled = environment.preferences.value.menuBarEnabled
                menuBarController.update(
                    enabled: environment.preferences.value.menuBarEnabled,
                    environment: environment
                )
                environment.applySchedulePreference()
            }
            .onChange(of: environment.preferences.value.menuBarEnabled) { _, enabled in
                appDelegate.isMenuBarEnabled = enabled
                menuBarController.update(enabled: enabled, environment: environment)
            }
    }
}
