import Foundation

/// Internal re-measurement of logical bytes on disk (regular files only,
/// symlinks never followed — I7). CleanupExecutor uses it for MEASURED
/// `bytesFreed`. Kept inside Cleaning so the executor never depends on
/// Scanning; once the scan engine's DirectorySizeCalculator lands it can be
/// retired in its favor.
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

    private static func fileBytes(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return 0 }
        return Int64(size)
    }
}
