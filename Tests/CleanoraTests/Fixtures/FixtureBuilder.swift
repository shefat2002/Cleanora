import Foundation
@testable import Cleanora

/// Builds deterministic directory trees for engine tests.
enum FixtureBuilder {
    /// Creates files (with zero-padded content of roughly `size` bytes) and
    /// intermediate directories from relative paths. Returns the root.
    @discardableResult
    static func makeTree(
        in root: URL,
        _ entries: [(path: String, size: Int)]
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for entry in entries {
            let fileURL = root.appendingPathComponent(entry.path)
            try fm.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data(repeating: 0x41, count: entry.size)
            try data.write(to: fileURL, options: .atomic)
        }
        return root
    }

    /// Convenience: creates the skeleton a ScanEnvironment expects
    /// (Caches, Logs, .Trash) under `home`.
    @discardableResult
    static func makeHomeSkeleton(in home: URL) throws -> URL {
        let fm = FileManager.default
        for component in ["Library/Caches", "Library/Logs", ".Trash"] {
            try fm.createDirectory(
                at: home.appendingPathComponent(component),
                withIntermediateDirectories: true
            )
        }
        return home
    }
}
