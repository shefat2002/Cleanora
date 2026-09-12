import Foundation

/// Shared internal helpers for the concrete scanners: root usability checks,
/// staleness decisions and friendly naming. Kept in one place so every
/// scanner maps the same filesystem condition to the same `SkipReason`.
enum ScannerGuards {
    /// The skip reason for an unusable root, or nil when scanning may proceed.
    static func skipReason(root: URL, environment: ScanEnvironment) -> SkipReason? {
        if !environment.exists(root) { return .pathNotFound(root.path) }
        if !environment.readable(root) { return .permissionDenied(root.path) }
        return nil
    }

    /// Combined skip reason across several roots: pathNotFound only when none
    /// exist, permissionDenied when the remainder is unreadable.
    static func skipReason(roots: [URL], environment: ScanEnvironment) -> SkipReason? {
        let missing = roots.filter { !environment.exists($0) }
        if missing.count == roots.count {
            return .pathNotFound(missing.map(\.path).joined(separator: ", "))
        }
        let denied = roots.filter { environment.exists($0) && !environment.readable($0) }
        if missing.count + denied.count == roots.count {
            return .permissionDenied(denied.map(\.path).joined(separator: ", "))
        }
        return nil
    }

    /// An entry is stale when its modification time is at least `cutoff`
    /// seconds in the past. Entries with an unknown mtime are treated as
    /// fresh (never cleaned on a guess).
    static func isStale(modificationDate: Date?, olderThan cutoff: TimeInterval) -> Bool {
        guard let modificationDate else { return false }
        return modificationDate.timeIntervalSinceNow < -cutoff
    }

    /// Allocated size of a single regular file. `DirectorySizeCalculator`
    /// only walks directories — loose files are measured from their already
    /// prefetched resource values.
    static func fileSize(from values: URLResourceValues?) -> Int64 {
        guard let values else { return 0 }
        if let allocated = values.totalFileAllocatedSize { return Int64(allocated) }
        if let logical = values.fileSize { return Int64(logical) }
        return 0
    }
}

/// Directory-name → human label. "com.apple.dt.Xcode" → "Xcode",
/// "io.github.some-tool" → "Some Tool", "pip" → "Pip".
enum FriendlyNaming {
    static func appName(forBundleID bundleID: String?, fallbackName: String) -> String {
        let base = bundleID?.split(separator: ".").last.map(String.init) ?? fallbackName
        let words = base
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
        return words.isEmpty ? base : words.joined(separator: " ")
    }
}

extension URL {
    /// Appends path components one by one — `caches.appending(["Google", "Chrome"])`.
    func appending(_ components: [String]) -> URL {
        components.reduce(self) { $0.appendingPathComponent($1, isDirectory: true) }
    }
}
