import AppKit
import Foundation

/// Seam for "Reveal in Finder" (P-09) so view models stay testable; the
/// AppKit call lives in the App layer, same as PermissionProbe.
struct FileRevealer: Sendable {
    var reveal: @MainActor @Sendable (URL) -> Void

    static func live() -> FileRevealer {
        FileRevealer { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
