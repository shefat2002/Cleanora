import SwiftUI

@main
struct CleanoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .frame(minWidth: 720, minHeight: 520)
                .frame(width: 900, height: 620)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}
