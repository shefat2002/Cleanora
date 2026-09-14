import Foundation

/// M-03 — turns a finished `ScanResult` into at most four dashboard
/// suggestions, largest estimated saving first.
///
/// Ground rules, enforced by tests:
/// - Rules read ONLY item categories, sizes, appName groups and paths.
///   `CleanupItem.reason` is user copy, never a data source — a reason that
///   happens to mention Docker must not conjure a Docker suggestion.
/// - Every threshold is STRICT (`>`): a result sitting exactly at a
///   threshold recommends nothing.
/// - The output is never auto-selected anywhere: a `Recommendation` is an
///   inert card that routes the user back into review.
///
/// The engine is a stateless value type; `recommendations(from:)` is pure.
public struct RecommendationEngine: Sendable {
    /// Decimal bytes, matching `ByteCountFormatting` (1 GB = 10⁹).
    public static let archiveThreshold: Int64 = 500_000_000
    public static let deviceSupportThreshold: Int64 = 1_000_000_000
    public static let homebrewThreshold: Int64 = 2_000_000_000
    public static let dockerThreshold: Int64 = 10_000_000_000
    public static let trashThreshold: Int64 = 5_000_000_000
    public static let logsThreshold: Int64 = 1_000_000_000

    /// No dashboard shows more than a handful of cards; the biggest savings
    /// win, ties break by title so the order is deterministic.
    public static let maximumRecommendations = 4

    public init() {}

    public static func recommendations(from result: ScanResult) -> [Recommendation] {
        var candidates: [Recommendation] = []

        let developerItems = result.items.filter { $0.category == .developerData }

        let archiveBytes = totalSize(of: developerItems) {
            $0.path.contains(pathComponents: ["Library", "Developer", "Xcode", "Archives"])
        }
        if archiveBytes > archiveThreshold {
            candidates.append(Recommendation(
                title: "Old Xcode archives",
                detail: "Xcode archives are the distributable builds made from this Mac. You have \(archiveBytes.formattedByteCount) of them — keep the ones you may need to re-upload or symbolicate, and remove the rest.",
                estimatedBytes: archiveBytes,
                category: .developerData
            ))
        }

        let deviceSupportBytes = totalSize(of: developerItems) {
            $0.path.contains(pathComponents: ["Library", "Developer", "Xcode", "iOS DeviceSupport"])
        }
        if deviceSupportBytes > deviceSupportThreshold {
            candidates.append(Recommendation(
                title: "Old iOS device symbols",
                detail: "\(deviceSupportBytes.formattedByteCount) of symbol files were copied from connected iPhone and iPad OS versions. They re-download when a device with that OS version connects again.",
                estimatedBytes: deviceSupportBytes,
                category: .developerData
            ))
        }

        let homebrewBytes = totalSize(of: developerItems) {
            $0.path.contains(pathComponents: ["Library", "Caches", "Homebrew"])
        }
        if homebrewBytes > homebrewThreshold {
            candidates.append(Recommendation(
                title: "Homebrew cache is large",
                detail: "\(homebrewBytes.formattedByteCount) of downloaded packages sit in Homebrew's cache. Homebrew re-downloads anything it needs; clearing the cache uninstalls nothing.",
                estimatedBytes: homebrewBytes,
                category: .developerData
            ))
        }

        // Docker is identified by its appName group alone: the scanner's item
        // path is a gate-rejected marker directory whose meaning lives in the
        // reason string — which rules must never read.
        let dockerBytes = totalSize(of: developerItems) { $0.appName == "Docker" }
        if dockerBytes > dockerThreshold {
            candidates.append(Recommendation(
                title: "Docker is using a lot of space",
                detail: "\(dockerBytes.formattedByteCount) live inside Docker's disk image, which holds images, containers and build cache. Cleanora never deletes that file — use Docker's own prune command to reclaim the space.",
                estimatedBytes: dockerBytes,
                category: .developerData
            ))
        }

        let trashBytes = totalSize(of: result.items) { $0.category == .trash }
        if trashBytes > trashThreshold {
            candidates.append(Recommendation(
                title: "Trash is filling up",
                detail: "\(trashBytes.formattedByteCount) sit in the Trash. Emptying it frees the space immediately, but the items are gone for good.",
                estimatedBytes: trashBytes,
                category: .trash
            ))
        }

        let logsBytes = totalSize(of: result.items) { $0.category == .logs }
        if logsBytes > logsThreshold {
            candidates.append(Recommendation(
                title: "Old logs are piling up",
                detail: "\(logsBytes.formattedByteCount) of logs and diagnostic reports. Old ones are debugging history only; removing them does not affect your apps.",
                estimatedBytes: logsBytes,
                category: .logs
            ))
        }

        return Array(
            candidates
                .sorted { lhs, rhs in
                    if lhs.estimatedBytes != rhs.estimatedBytes {
                        return lhs.estimatedBytes > rhs.estimatedBytes
                    }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                .prefix(maximumRecommendations)
        )
    }

    // MARK: - Helpers

    private static func totalSize(
        of items: [CleanupItem],
        where predicate: (CleanupItem) -> Bool
    ) -> Int64 {
        items
            .filter(predicate)
            .reduce(Int64(0)) { $0 + $1.size }
    }
}

extension URL {
    /// True when the URL's path contains `components` as a contiguous
    /// subsequence of path components — "…/Library/Developer/Xcode/Archives"
    /// matches, "…/Library/Developer/Xcode/ArchivesExtra" does not.
    fileprivate func contains(pathComponents components: [String]) -> Bool {
        let parts = standardizedFileURL.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.count <= parts.count else { return false }
        for start in 0...(parts.count - components.count) {
            if Array(parts[start..<(start + components.count)]) == components {
                return true
            }
        }
        return false
    }
}
