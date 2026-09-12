import Foundation

/// Internal re-measurement of ALLOCATED bytes on disk (regular files only,
/// symlinks never followed — I7). CleanupExecutor uses it for MEASURED
/// `bytesFreed`; allocated size matches what the scan pipeline reports
/// (DirectorySizeCalculator) and what the disk actually regains, so progress
/// ends at 100% instead of drifting below on block-rounded files.
/// Kept inside Cleaning so the executor never depends on Scanning.
struct ContentSizeProbe: Sendable {
    /// Guards against pathological directory depth (legit deep trees such as
    /// node_modules stay well below this).
    private static let maxDepth = 100

    /// nil when the path does not exist.
    func logicalBytes(at url: URL) -> Int64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        guard isDirectory.boolValue else {
            return Self.fileBytes(url)
        }
        return directoryBytes(url, depth: 0)
    }

    private func directoryBytes(_ directory: URL, depth: Int) -> Int64 {
        guard depth <= Self.maxDepth else { return 0 }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: []
        )) ?? []

        var total: Int64 = 0
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true {
                continue // I7: symlinks contribute nothing, targets untouched
            }
            if values?.isDirectory == true {
                total += directoryBytes(child, depth: depth + 1)
            } else {
                total += Self.fileBytes(child)
            }
        }
        return total
    }

    /// Allocated size with logical fallback (sparse-aware, block-rounded —
    /// the unit disk regains on deletion).
    private static func fileBytes(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else {
            return 0
        }
        if let allocated = values.totalFileAllocatedSize { return Int64(allocated) }
        return Int64(values.fileSize ?? 0)
    }
}
