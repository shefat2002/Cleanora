import Foundation

/// E-03 — the single recursive enumeration primitive of the scan engine.
///
/// Depth-capped and time-budgeted; checks cancellation at directory
/// boundaries (never per file, which would dominate the cost). Symlinks are
/// reported as entries but never descended into (invariant I7); unreadable
/// directories are skipped silently — enumeration must never abort a scan.
public struct FileSystemWalker: Sendable {
    public struct Options: Sendable {
        /// Maximum directory depth below the root that is descended into.
        /// The root's direct children are at depth 1.
        public var maxDepth: Int
        /// Wall-clock budget for the whole traversal; exceeded → `hitTimeBudget`.
        public var timeBudget: TimeInterval?

        public init(maxDepth: Int = 64, timeBudget: TimeInterval? = nil) {
            self.maxDepth = maxDepth
            self.timeBudget = timeBudget
        }
    }

    public struct Report: Sendable, Equatable {
        /// Every entry below the root (files, directories, symlinks), in
        /// enumeration order. The root itself is never included.
        public let entries: [URL]
        /// True when the traversal stopped because the time budget ran out.
        public let hitTimeBudget: Bool

        public init(entries: [URL], hitTimeBudget: Bool) {
            self.entries = entries
            self.hitTimeBudget = hitTimeBudget
        }
    }

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isRegularFileKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey,
    ]

    /// `URL.resourceValues(forKeys:)` wants a set; keep one shape around so
    /// callers never rebuild it per entry.
    static var resourceKeySet: Set<URLResourceKey> { Set(resourceKeys) }

    private let options: Options

    public init(options: Options = .init()) {
        self.options = options
    }

    /// Direct children of `directory`, hidden entries included, symlinks
    /// returned as links (never resolved). Throws if the directory cannot be
    /// read — callers decide whether that means skip or permission-denied.
    public func children(of directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Self.resourceKeys,
            options: []
        )
    }

    /// Enumerates everything below `root`, depth-first. Options passed here
    /// override the ones the walker was created with.
    public func descendants(
        of root: URL,
        options: Options? = nil,
        shouldContinue: @escaping @Sendable () -> Bool = { !Task.isCancelled }
    ) -> Report {
        let effectiveOptions = options ?? self.options
        let deadline = effectiveOptions.timeBudget.map { Date().addingTimeInterval($0) }

        var entries: [URL] = []
        var hitTimeBudget = false

        func recurse(_ directory: URL, depth: Int) {
            guard depth < effectiveOptions.maxDepth else { return }
            if let deadline, Date() >= deadline {
                hitTimeBudget = true
                return
            }
            guard shouldContinue(), !Task.isCancelled else { return }

            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Self.resourceKeys,
                    options: []
                )
            } catch {
                return // unreadable — skip, never abort the traversal
            }
            for child in children {
                entries.append(child)
                let values = try? child.resourceValues(forKeys: Self.resourceKeySet)
                guard values?.isSymbolicLink != true else { continue } // I7
                if values?.isDirectory == true {
                    recurse(child, depth: depth + 1)
                }
            }
        }

        recurse(root, depth: 0)
        return Report(entries: entries, hitTimeBudget: hitTimeBudget)
    }
}
