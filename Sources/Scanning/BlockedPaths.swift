import Foundation

/// Scanning-side mirror of SafetyPolicy's forbidden set (Cleaning layer).
///
/// Scanning cannot import Cleaning — Cleaning depends on Scanning — so the
/// blocked roots, fragments and Cleanora's own Application Support subtree
/// (I10) are duplicated here for producers that must pre-filter what they
/// report (LargeFileScanner). Keep in sync with `SafetyPolicy.standard`;
/// `BlockedPathsTests` pins the two lists to each other so drift fails tests.
enum BlockedPaths {
    /// Subtrees forbidden even inside an allowed root (I3), matched anywhere
    /// in a path.
    static let blockedFragments: Set<String> = [
        "Mobile Documents", "Keychains", "MobileSync", "iCloud Drive",
        "com.apple.LaunchServices",
    ]

    /// Path components of every blocked root, relative to the home directory.
    /// Mirrors SafetyPolicy's blockedPaths plus its I10 exclusion.
    private static let blockedRootComponents: [[String]] = [
        ["Library", "Keychains"],
        ["Library", "Mail"],
        ["Library", "Messages"],
        ["Library", "Safari"],
        ["Library", "Metadata"],
        ["Library", "Preferences"],
        ["Library", "Application Support", "MobileSync"],
        ["Library", "Mobile Documents"],
        ["Desktop"],
        ["Documents"],
        ["Downloads"],
        ["Pictures"],
        ["Music"],
        ["Movies"],
        ["Public"],
        ["Library", "Application Support", "Cleanora"], // I10: never scan our own data
    ]

    /// Blocked roots under `home`, in the same path spelling as `home` so
    /// prefix comparisons against walked children stay consistent.
    static func blockedRoots(home: URL) -> [URL] {
        blockedRootComponents.map { home.appending($0) }
    }

    /// Prefix strings for blocked roots, built on the CANONICALIZED home.
    /// FileManager hands out `/private/var/…` spellings for children of a
    /// `/var/…` directory, so raw string prefixes against home-derived roots
    /// silently never match — every prefix comparison in a walk must run on
    /// one canonical spelling.
    static func canonicalPrefixes(
        home: URL,
        additionalComponents: [[String]] = []
    ) -> [String] {
        let canonicalHome = PathNormalizer.canonicalized(home).path
        return (blockedRootComponents + additionalComponents)
            .map { canonicalHome + "/" + $0.joined(separator: "/") }
    }

    /// True when `canonicalPath` (already in canonical spelling) sits inside
    /// one of `prefixes` (from `canonicalPrefixes`) or contains a fragment.
    static func isBlocked(
        _ canonicalPath: String,
        prefixes: [String],
        fragments: Set<String> = BlockedPaths.blockedFragments
    ) -> Bool {
        if prefixes.contains(where: { canonicalPath == $0 || canonicalPath.hasPrefix($0 + "/") }) {
            return true
        }
        return fragments.contains { canonicalPath.contains($0) }
    }

    /// Convenience predicate with per-call canonicalization. The walk uses
    /// `canonicalPrefixes` + `isBlocked(_:prefixes:fragments:)` instead —
    /// canonicalizing every walked child would cost one realpath each.
    static func isBlocked(_ path: String, home: URL) -> Bool {
        let canonical = PathNormalizer.canonicalized(URL(fileURLWithPath: path)).path
        return isBlocked(canonical, prefixes: canonicalPrefixes(home: home))
    }
}
