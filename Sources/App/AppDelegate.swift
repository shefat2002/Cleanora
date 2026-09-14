import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// M-01: when the menu bar item is enabled, closing the main window keeps
    /// the app running in the menu bar. Synced from CleanoraApp whenever the
    /// preference changes.
    var isMenuBarEnabled = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !isMenuBarEnabled
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(self)
        }
        return true
    }
}
