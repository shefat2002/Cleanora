import AppKit
import Foundation

/// Seam for the duplicate finder's folder chooser (M-04) so the view model
/// stays testable; the NSOpenPanel call lives in the App layer, same as
/// PermissionProbe and FileRevealer. Returns nil when the user cancels.
struct FolderPicker: Sendable {
    var pickDirectory: @MainActor @Sendable () -> URL?

    static func live() -> FolderPicker {
        FolderPicker {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.message = "Choose a folder to search for duplicate files."
            panel.prompt = "Add"
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
    }
}
