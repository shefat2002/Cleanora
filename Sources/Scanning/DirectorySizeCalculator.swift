import Foundation

/// E-02 — measures a directory tree: allocated bytes and regular-file count.
///
/// - Sizes are **allocated** bytes (`.totalFileAllocatedSizeKey`), falling
///   back to logical size when allocation is unavailable. This is what the
///   filesystem actually holds, and what deletion frees.
/// - Symlinks are neither followed nor counted (invariant I7).
/// - Unreadable directories are skipped, never fatal.
/// - Directories are measured in parallel with a bounded TaskGroup
///   (`maximumConcurrentDirectories`); cancellation is checked per directory.
public struct DirectorySizeCalculator: Sendable {
    public struct Result: Sendable, Equatable {
        public var bytes: Int64
        public var fileCount: Int
        /// True when the traversal stopped early because the time budget ran
        /// out — the numbers are then partial by definition.
        public var hitTimeBudget: Bool

        public init(bytes: Int64 = 0, fileCount: Int = 0, hitTimeBudget: Bool = false) {
            self.bytes = bytes
            self.fileCount = fileCount
            self.hitTimeBudget = hitTimeBudget
        }

        public var isEmpty: Bool { bytes == 0 && fileCount == 0 }

        mutating func merge(_ other: Result) {
            bytes += other.bytes
            fileCount += other.fileCount
            hitTimeBudget = hitTimeBudget || other.hitTimeBudget
        }
    }

    /// Scan parallelism cap: at most 8 directory measurements in flight, or
    /// twice the core count on smaller machines — whichever is lower.
    public static let maximumConcurrentDirectories = min(
        8,
        ProcessInfo.processInfo.activeProcessorCount * 2
    )

    private let walker = FileSystemWalker()

    public init() {}

    /// Measures `root` recursively. Returns partial numbers (with
    /// `hitTimeBudget == true`) when the budget expires, and whatever was
    /// accumulated when cancelled — never throws.
    public func measure(
        at root: URL,
        timeBudget: TimeInterval? = nil,
        shouldContinue: @escaping @Sendable () -> Bool = { !Task.isCancelled }
    ) async -> Result {
        let deadline = timeBudget.map { Date().addingTimeInterval($0) }
        var total = Result()
        var frontier: [URL] = [root]

        while !frontier.isEmpty {
            if let deadline, Date() >= deadline {
                total.hitTimeBudget = true
                break
            }
            let batch = Array(frontier.prefix(Self.maximumConcurrentDirectories))
            frontier.removeFirst(batch.count)

            var discovered: [URL] = []
            await withTaskGroup(of: Measurement.self) { group in
                for directory in batch {
                    group.addTask {
                        self.measureSingle(directory, shouldContinue: shouldContinue)
                    }
                }
                for await measurement in group {
                    total.merge(measurement.result)
                    discovered.append(contentsOf: measurement.subdirectories)
                }
            }
            frontier.append(contentsOf: discovered)
        }
        return total
    }

    // MARK: - Internals

    /// One directory's contribution: its own files plus the subdirectories to
    /// queue. Runs synchronously inside a group child task.
    private func measureSingle(
        _ directory: URL,
        shouldContinue: @escaping @Sendable () -> Bool
    ) -> Measurement {
        guard shouldContinue(), !Task.isCancelled else {
            return Measurement(result: Result(), subdirectories: [])
        }

        let children: [URL]
        do {
            children = try walker.children(of: directory)
        } catch {
            return Measurement(result: Result(), subdirectories: []) // unreadable: skip
        }

        var result = Result()
        var subdirectories: [URL] = []
        for child in children {
            guard let values = try? child.resourceValues(forKeys: FileSystemWalker.resourceKeySet)
            else { continue }
            if values.isSymbolicLink == true { continue } // I7: never follow, never count
            if values.isDirectory == true {
                subdirectories.append(child)
                continue
            }
            if values.isRegularFile == true || values.fileSize != nil
                || values.totalFileAllocatedSize != nil {
                result.fileCount += 1
                result.bytes += Self.allocatedBytes(of: values)
            }
            // Sockets, FIFOs and devices contribute no measurable bytes.
        }
        return Measurement(result: result, subdirectories: subdirectories)
    }

    private static func allocatedBytes(of values: URLResourceValues) -> Int64 {
        if let allocated = values.totalFileAllocatedSize { return Int64(allocated) }
        if let logical = values.fileSize { return Int64(logical) }
        return 0
    }

    private struct Measurement: Sendable {
        let result: Result
        let subdirectories: [URL]
    }
}
