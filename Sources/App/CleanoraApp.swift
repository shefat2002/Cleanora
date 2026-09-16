import SwiftUI

@main
struct CleanoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

    // body is split into builder properties: the scenes + modifiers in one
    // expression exceeded the type checker's budget. The menu bar item is
    // NOT a scene — SceneBuilder's buildIf + MenuBarExtra crashes this
    // toolchain's type checker, so MenuBarController (NSStatusItem + popover)
    // owns its appearance instead. It lives in AppEnvironment so the toggle
    // works from Settings even when the main window is CLOSED (the Settings
    // scene survives; MainSceneRoot's onChange does not).
    var body: some Scene {
        mainScene
        settingsScene
    }

    private var mainScene: some Scene {
        WindowGroup(id: MenuBarPanelView.mainWindowID) {
            MainSceneRoot(appDelegate: appDelegate)
                .environment(environment)
                .frame(minWidth: 720, minHeight: 520)
                .frame(width: 900, height: 620)
        }
        .windowResizability(.contentMinSize)
        // Keyboard shortcuts (⌘R scan, ⌘1 dashboard) attach to the main
        // window's scene only — Settings and the NSStatusItem popover are
        // unaffected. environment is passed by init parameter: commands do
        // not participate in .environment() propagation.
        .commands {
            CleanoraCommands(environment: environment)
        }
    }

    private var settingsScene: some Scene {
        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}

/// WindowGroup content (a real View, so `openWindow` resolves here): hands
/// the environment its app delegate + window-opening action, applies the
/// menu-bar and schedule preferences once at launch, and starts the schedule
/// loop when the preference asks for it.
private struct MainSceneRoot: View {
    let appDelegate: AppDelegate
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openMainWindow

    var body: some View {
        RootView()
            .task {
                environment.appDelegate = appDelegate
                environment.openMainWindowHandler = {
                    openMainWindow(id: MenuBarPanelView.mainWindowID)
                }
                environment.applyMenuBarPreference()
                environment.applySchedulePreference()
            }
    }
}
