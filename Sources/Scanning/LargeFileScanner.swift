import Foundation

/// C-07 — large files: every regular file at or above
/// `options.largeFileMinimumBytes` under the home subtree, at most
/// `options.largeFileLimit` of them, largest first. Findings are always
/// `.review` + `.moveToTrash` (recoverable) and never preselected — the user
/// decides file by file.
///
/// Scope: home subtree at depth ≤ 4. Blocked roots/fragments (`BlockedPaths`,
/// the Scanning-side mirror of SafetyPolicy's forbidden set) are PRUNED during
/// the walk, so Documents/Downloads/… are never read and blocked fragments
/// can never surface; `.Trash` is excluded because TrashScanner owns that
/// content. Symlinks are neither followed nor counted (I7). The
/// `options.perScanTimeBudget` caps the walk: exceeding it keeps the findings
/// so far and emits a `.tooLargeToScan` note (a fully empty walk reports
/// `.skipped(.tooLargeToScan)`).
public struct LargeFileScanner: Scanner {
    public let category: ScanCategory = .largeFiles
    public let progressKey: ScannerKey
    public let isPhaseOne: Bool = false

    /// Maximum directory depth below home; its children are at depth 1.
    static let maximumDepth = 4
    /// TrashScanner reports `.Trash` as one unit — large-file findings inside
    /// it would double count and break the trash-emptying flow.
    static let additionalExclusions: [[String]] = [[".Trash"]]
    /// How often the walk yields to the cooperative pool.
    private static let yieldInterval = 128

    public init() {
        self.progressKey = ScannerKey(id: .largeFiles)
    }

    public func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome {
        guard options.enabledCategories.contains(.largeFiles) else {
            return .skipped(.disabledByUser)
        }
        guard !Task.isCancelled else { return .produced([]) }
        onProgress(progressKey, .running(bytesScanned: 0, itemsFound: 0))

        let walk = await Self.walk(
            from: environment.home,
            minimumBytes: options.largeFileMinimumBytes,
            maximumDepth: Self.maximumDepth,
            deadline: Date().addingTimeInterval(options.perScanTimeBudget),
            onProgress: onProgress,
            progressKey: progressKey
        )

        let threshold = options.largeFileMinimumBytes
        let selected = walk.candidates
            .sorted { $0.size == $1.size ? $0.url.path < $1.url.path : $0.size > $1.size }
            .prefix(options.largeFileLimit)

        let items = selected.map { candidate in
            CleanupItem(
                name: candidate.url.lastPathComponent,
                appName: nil,
                category: .largeFiles,
                path: candidate.url,
                size: candidate.size,
                fileCount: 1,
                riskLevel: .review,
                reason: "This file takes up \(candidate.size.formattedByteCount). Cleanora lists every file of at least \(threshold.formattedByteCount) for review — move it to the Trash only if you no longer need it.",
                deletionMethod: .moveToTrash
            )
        }

        if walk.hitTimeBudget {
            onProgress(progressKey, .skipped(.tooLargeToScan))
            if items.isEmpty {
                return .skipped(.tooLargeToScan)
            }
        }
        return .produced(Array(items))
    }

    // MARK: - Walk

    struct Candidate: Sendable, Equatable {
        let url: URL
        let size: Int64
    }

    struct WalkResult: Sendable {
        let candidates: [Candidate]
        let hitTimeBudget: Bool
    }

    /// Iterative, depth-capped frontier walk with blocked-subtree pruning and
    /// per-directory cancellation. The budget check runs AFTER each directory
    /// is processed, so a zero budget still yields the home directory's own
    /// direct files — a deterministic partial result.
    ///
    /// Paths carried on the frontier are CANONICAL spellings built from the
    /// canonicalized home: FileManager enumerates a `/var/…` directory as
    /// `/private/var/…` children, so raw prefixes against home-derived roots
    /// would silently never match. Child paths are composed from the parent's
    /// canonical path — no realpath per entry.
    static func walk(
        from home: URL,
        minimumBytes: Int64,
        maximumDepth: Int,
        deadline: Date?,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void,
        progressKey: ScannerKey
    ) async -> WalkResult {
        let walker = FileSystemWalker()
        let blockedPrefixes = BlockedPaths.canonicalPrefixes(
            home: home,
            additionalComponents: additionalExclusions
        )
        let fragments = BlockedPaths.blockedFragments

        var candidates: [Candidate] = []
        var discoveredBytes: Int64 = 0
        var frontier: [(url: URL, canonical: String, depth: Int)] = [
            (home, PathNormalizer.canonicalized(home).path, 0)
        ]
        var hitTimeBudget = false
        var visits = 0

        while let (directory, canonical, depth) = frontier.popLast() {
            if Task.isCancelled { break }
            let children: [URL]
            do {
                children = try walker.children(of: directory)
            } catch {
                continue // unreadable: skip, never abort the walk
            }

            for child in children {
                // Directories at `maximumDepth - 1` hold the deepest in-scope
                // files (depth `maximumDepth`); deeper directories are never
                // entered, so their depth-`maximumDepth + 1` files stay out.
                guard depth < maximumDepth else { continue }
                let childCanonical = canonical + "/" + child.lastPathComponent
                if BlockedPaths.isBlocked(childCanonical, prefixes: blockedPrefixes, fragments: fragments) {
                    continue
                }
                guard let values = try? child.resourceValues(forKeys: FileSystemWalker.resourceKeySet)
                else { continue }
                if values.isSymbolicLink == true { continue } // I7
                if values.isDirectory == true {
                    frontier.append((child, childCanonical, depth + 1))
                    continue
                }
                if values.isRegularFile != true {
                    continue // sockets, FIFOs, devices: never cleanup targets
                }
                let size = ScannerGuards.fileSize(from: values)
                guard size >= minimumBytes else { continue }
                candidates.append(Candidate(url: child, size: size))
                discoveredBytes += size
                onProgress(progressKey, .running(
                    bytesScanned: discoveredBytes, itemsFound: candidates.count
                ))
            }

            visits += 1
            if visits % Self.yieldInterval == 0 {
                // Hand the cooperative pool a breath; enumeration itself
                // stays synchronous like FileSystemWalker's traversals.
                await Task.yield()
            }
            if let deadline, Date() >= deadline {
                hitTimeBudget = true
                break
            }
        }
        return WalkResult(candidates: candidates, hitTimeBudget: hitTimeBudget)
    }
}
