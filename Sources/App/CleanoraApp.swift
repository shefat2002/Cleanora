import SwiftUI

@main
struct CleanoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

    // body is split into builder properties: the three scenes + modifiers in
    // one expression exceeded the type checker's budget.
    var body: some Scene {
        mainScene
        settingsScene
        menuBarScene
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

    /// M-01: the menu bar item only exists while the preference is on.
    /// SceneBuilder supports conditional scenes, so toggling Settings
    /// adds/removes the extra live.
    private var isMenuBarEnabled: Bool {
        environment.preferences.value.menuBarEnabled
    }

    @SceneBuilder
    private var menuBarScene: some Scene {
        if isMenuBarEnabled {
            menuBarExtra
        } else {
            EmptyScene()
        }
    }

    private var menuBarExtra: some Scene {
        MenuBarExtra {
            Text("menu bar placeholder")
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)
    }

    /// Closing the main window must not quit the app while the menu bar item
    /// is alive; the delegate re-checks on every window close.
    private func syncMenuBarState() {
        appDelegate.isMenuBarEnabled = environment.preferences.value.menuBarEnabled
    }
}

/// The menu bar extra's content, extracted so the scene builder expression
/// stays inside the type checker's budget.
private struct MenuBarSceneContent: View {
    let environment: AppEnvironment

    var body: some View {
        MenuBarPanelView()
            .environment(environment)
    }
}
