import Foundation

/// Result of one destructive operation — status before any byte measurement.
public struct DeletionResult: Sendable, Equatable {
    public enum Kind: Equatable, Sendable {
        /// Nothing of the item remains at its original path.
        case removed
        /// Some content remains (children that refused to go).
        case partial
        /// Nothing was removed.
        case failed
        /// The path was already gone — nothing to do.
        case alreadyGone
    }

    public let kind: Kind
    public let message: String?

    public init(kind: Kind, message: String? = nil) {
        self.kind = kind
        self.message = message
    }
}

/// Performs one item's destructive operation according to its DeletionMethod:
/// - removeContents: delete children of the directory, KEEP the directory.
///   PERMANENT — SafetyPolicy only allows it for regenerable `.safe` data.
/// - trashDirectory / moveToTrash: recoverable move into the Trash via
///   FileManager.trashItem (or the injected TrashMove). A refused trash move
///   NEVER falls back to a permanent rm.
/// - Any path already inside ~/.Trash is removed in place: trashItem on an
///   in-Trash path would error (moving the Trash into itself).
/// Every failure is returned as a result — nothing ever throws past the
/// caller, so one bad item cannot abort a batch (I11).
public struct DeletionMethodExecutor: Sendable {
    public typealias TrashMove = @Sendable (URL) throws -> URL

    private let trashMove: TrashMove

    public init() {
        // Default: the real, recoverable move into the user's Trash.
        self.trashMove = { url in
            var destination: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
            return destination as URL? ?? url
        }
    }

    /// Test seam: stages trash semantics without touching the real Trash.
    public init(trashMove: @escaping TrashMove) {
        self.trashMove = trashMove
    }

    public func delete(_ item: CleanupItem, home: URL) -> DeletionResult {
        let path = SafetyPolicy.canonicalized(item.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            return DeletionResult(kind: .alreadyGone, message: "No longer present")
        }

        let trash = SafetyPolicy.canonicalized(
            home.appendingPathComponent(".Trash", isDirectory: true)
        )
        if path.path == trash.path || path.path.hasPrefix(trash.path + "/") {
            return isDirectory.boolValue
                ? removeContents(of: path)
                : removeSingleItem(at: path)
        }

        switch item.deletionMethod {
        case .removeContents:
            return isDirectory.boolValue
                ? removeContents(of: path)
                : removeSingleItem(at: path)
        case .trashDirectory, .moveToTrash:
            return moveToTrash(path)
        }
    }

    private func moveToTrash(_ path: URL) -> DeletionResult {
        do {
            _ = try trashMove(path)
        } catch {
            return DeletionResult(
                kind: .failed,
                message: "Move to Trash failed: \(error.localizedDescription)"
            )
        }
        guard !FileManager.default.fileExists(atPath: path.path) else {
            return DeletionResult(
                kind: .failed,
                message: "Item still present after trash move"
            )
        }
        return DeletionResult(kind: .removed)
    }

    private func removeContents(of directory: URL) -> DeletionResult {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: []
            )
        } catch {
            return DeletionResult(
                kind: .failed,
                message: "Could not list contents: \(error.localizedDescription)"
            )
        }
        guard !children.isEmpty else {
            return DeletionResult(kind: .removed)
        }

        var removedCount = 0
        var failures: [String] = []
        for child in children.sorted(by: { $0.path < $1.path }) {
            do {
                // removeItem unlinks symlinks rather than following them (I7).
                try FileManager.default.removeItem(at: child)
                removedCount += 1
            } catch {
                failures.append("\(child.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard !failures.isEmpty else {
            return DeletionResult(kind: .removed)
        }
        return DeletionResult(
            kind: removedCount > 0 ? .partial : .failed,
            message: "\(failures.count) of \(children.count) item(s) could not be removed: "
                + failures.prefix(3).joined(separator: "; ")
        )
    }

    private func removeSingleItem(at path: URL) -> DeletionResult {
        do {
            try FileManager.default.removeItem(at: path)
            return DeletionResult(kind: .removed)
        } catch {
            return DeletionResult(kind: .failed, message: error.localizedDescription)
        }
    }
}
