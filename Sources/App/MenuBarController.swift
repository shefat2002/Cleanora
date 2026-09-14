import AppKit
import SwiftUI

/// M-01 menu bar presence, implemented with NSStatusItem + NSPopover.
///
/// The SwiftUI `MenuBarExtra` scene cannot be conditionally included: with
/// this toolchain, `SceneBuilder`'s buildIf + MenuBarExtra crashes the type
/// checker even in a minimal repro. An AppKit status item gives the same
/// behavior (appear/disappear with the preference) without the scene-graph
/// dance, and the app is non-sandboxed so AppKit is fully available.
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    /// Opening the main window from the panel routes through this (the panel
    /// view model already navigates; this activates the app).
    var activateMainWindow: (() -> Void)?

    func update(enabled: Bool, environment: AppEnvironment) {
        if enabled {
            installIfNeeded(environment: environment)
        } else {
            removeIfNeeded()
        }
    }

    private func installIfNeeded(environment: AppEnvironment) {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: "Cleanora"
        )
        let content = MenuBarPanelView().environment(environment)
        popover.contentViewController = NSHostingController(rootView: content)
        popover.behavior = .transient
        popover.animates = true

        let target = self as NSObject
        item.button?.target = target
        item.button?.action = #selector(statusItemClicked)
        statusItem = item
    }

    private func removeIfNeeded() {
        guard let item = statusItem else { return }
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            performClose()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func performClose() {
        popover.performClose(nil)
    }
}
