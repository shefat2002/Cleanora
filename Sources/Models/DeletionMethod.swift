import Foundation

/// Semantic contract enforced by DeletionMethodExecutor:
/// - removeContents: delete children of the directory, keep the directory.
///   PERMANENT — legal only for regenerable cache/temp/log roots.
/// - trashDirectory: move the entire directory to the Trash. Recoverable.
/// - moveToTrash: move a single file to the Trash. Recoverable.
public enum DeletionMethod: String, Codable, CaseIterable, Sendable {
    case removeContents
    case trashDirectory
    case moveToTrash

    public var isRecoverable: Bool { self != .removeContents }

    public var displayName: String {
        switch self {
        case .removeContents: return "Empty contents"
        case .trashDirectory: return "Move to Trash"
        case .moveToTrash: return "Move to Trash"
        }
    }
}
