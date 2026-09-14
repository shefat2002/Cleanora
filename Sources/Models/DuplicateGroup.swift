import Foundation

/// M-04 — one duplicate finding from `DuplicateScanner`.
///
/// Contract note for consumers: `files[0]` is the suggested KEEPER (the
/// newest file; equal modification times break to the lexicographically
/// smallest path, so the order is deterministic). Every following entry is a
/// duplicate. `totalWastedBytes` sums the duplicate copies' logical sizes —
/// never the keeper's.
public struct DuplicateGroup: Sendable, Equatable {
    public let files: [URL]
    public let totalWastedBytes: Int64

    public init(files: [URL], totalWastedBytes: Int64) {
        precondition(!files.isEmpty, "DuplicateGroup needs at least the keeper file")
        precondition(totalWastedBytes >= 0, "wasted bytes cannot be negative")
        self.files = files
        self.totalWastedBytes = totalWastedBytes
    }
}
