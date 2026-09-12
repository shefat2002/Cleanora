import Foundation

/// realpath()-based canonicalization used for overlap detection during dedup.
///
/// This deliberately mirrors `SafetyPolicy.canonicalized` (Cleaning layer).
/// Scanning cannot import Cleaning — Cleaning depends on Scanning — so the
/// identical algorithm lives here too. Keep the two in sync.
enum PathNormalizer {
    static func canonicalized(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL.path
        var buffer = [CChar](repeating: 0, count: 4096)
        if realpath(standardized, &buffer) != nil {
            return URL(fileURLWithPath: String(cString: buffer))
        }

        // Fall back to resolving the deepest existing ancestor; deletion
        // happens after validation, but the tail may already be gone.
        var suffix: [String] = []
        var probe = URL(fileURLWithPath: standardized)
        while probe.path != "/" && FileManager.default.fileExists(atPath: probe.path) == false {
            suffix.insert(probe.lastPathComponent, at: 0)
            probe = probe.deletingLastPathComponent()
        }
        if realpath(probe.path, &buffer) != nil {
            let real = String(cString: buffer).hasSuffix("/")
                ? String(String(cString: buffer).dropLast())
                : String(cString: buffer)
            return URL(fileURLWithPath: suffix.isEmpty
                ? real
                : real + "/" + suffix.joined(separator: "/"))
        }
        return URL(fileURLWithPath: standardized)
    }
}
