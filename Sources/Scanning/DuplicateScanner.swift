import CryptoKit
import Foundation

/// Progress for a duplicate scan: files that reached the hashing stage, the
/// bytes they account for, and the groups found so far.
public struct DuplicateProgress: Sendable, Equatable {
    public let filesExamined: Int
    public let bytesExamined: Int64
    public let duplicateGroupsFound: Int

    public init(filesExamined: Int, bytesExamined: Int64, duplicateGroupsFound: Int) {
        self.filesExamined = filesExamined
        self.bytesExamined = bytesExamined
        self.duplicateGroupsFound = duplicateGroupsFound
    }
}

/// M-04 configuration. Defaults keep a home-scale scan bounded: sub-1 MB
/// twins are not worth the hash, 2 000 candidates bound memory, and 60 s
/// bounds the whole run.
public struct DuplicateOptions: Sendable, Equatable {
    /// Only regular files of at least this LOGICAL size are candidates.
    public var minimumFileSize: Int64
    /// At most this many candidates (path-ordered) are considered.
    public var fileLimit: Int
    /// Soft budget: exceeded → the groups found so far are returned as a
    /// partial result.
    public var timeBudget: TimeInterval

    public init(
        minimumFileSize: Int64 = 1_000_000,
        fileLimit: Int = 2000,
        timeBudget: TimeInterval = 60
    ) {
        self.minimumFileSize = minimumFileSize
        self.fileLimit = fileLimit
        self.timeBudget = timeBudget
    }
}

/// M-04 — duplicate detection, scoped EXPLICITLY by the caller.
///
/// The scope is always user-chosen folders. There is no default root: the
/// scanner never walks home, /Applications or anything else on its own — a
/// home-wide duplicate pass is a UI decision, and if it is made, the
/// (optional) environment prunes the same blocked subtrees every other
/// scanner respects.
///
/// Pipeline: recursive walk (symlinks never followed, blocked subtrees
/// pruned, regular files only, size gate) → group by logical size → SHA-256
/// over the first 4 KB → full SHA-256 → one group per identical set. The
/// KEEPER is the newest file (`files[0]`); every other member is a
/// duplicate, and `totalWastedBytes` sums only those. Cancellation is
/// checked per directory and before every read and THROWS
/// `CancellationError`; the time budget instead ends the scan early with a
/// partial result. Grouping, keeper choice and output order are all
/// deterministic.
public struct DuplicateScanner: Sendable {
    /// How many leading bytes the cheap first-pass hash covers.
    static let headHashLength = 4_096
    /// Full-hash chunk size — files are streamed, never slurped whole.
    static let hashChunkBytes = 1 << 20

    public init() {}

    /// - Parameters:
    ///   - scope: user-chosen folders. MUST NOT default to anything.
    ///   - options: bounds and gates.
    ///   - environment: when provided, the home-derived blocked roots
    ///     (`BlockedPaths`) are pruned too — needed whenever the scope can
    ///     contain home. Without it, only blocked fragments apply.
    ///   - onProgress: fire-and-forget, throttling is the caller's business.
    public func findDuplicates(
        in scope: [URL],
        options: DuplicateOptions = DuplicateOptions(),
        environment: ScanEnvironment? = nil,
        onProgress: @escaping @Sendable (DuplicateProgress) -> Void = { _ in }
    ) async throws -> [DuplicateGroup] {
        guard !Task.isCancelled else { throw CancellationError() }
        guard !scope.isEmpty, options.fileLimit > 0 else { return [] }

        let deadline = Date().addingTimeInterval(options.timeBudget)
        let walk = collectCandidates(
            in: scope,
            minimumFileSize: options.minimumFileSize,
            environment: environment,
            deadline: deadline
        )

        // Deterministic candidate order + cap: the budget may cut the run
        // short, and a partial result must not depend on dictionary order.
        let candidates = walk.candidates
            .sorted { $0.url.path < $1.url.path }
            .prefix(max(0, options.fileLimit))

        var progress = DuplicateProgress(filesExamined: 0, bytesExamined: 0, duplicateGroupsFound: 0)
        var groups: [DuplicateGroup] = []

        let sizeBuckets = Dictionary(grouping: candidates, by: \.size)
        for (size, sameSizeUnsorted) in sizeBuckets.sorted(by: { $0.key < $1.key }) {
            let sameSize = sameSizeUnsorted.sorted { $0.url.path < $1.url.path }
            guard sameSize.count > 1 else { continue }

            var headBuckets: [Data: [Candidate]] = [:]
            for candidate in sameSize {
                try Task.checkCancellation()
                guard Date() < deadline else { return finalize(groups, progress: &progress, onProgress: onProgress) }
                guard let digest = digest(of: candidate.url, bytes: min(Self.headHashLength, Int(size)))
                else { continue }
                headBuckets[Data(digest), default: []].append(candidate)
                progress = DuplicateProgress(
                    filesExamined: progress.filesExamined + 1,
                    bytesExamined: progress.bytesExamined + candidate.size,
                    duplicateGroupsFound: progress.duplicateGroupsFound
                )
                onProgress(progress)
            }

            for (_, headGroup) in headBuckets.sorted(by: { $0.key.base64EncodedString() < $1.key.base64EncodedString() }) {
                guard headGroup.count > 1 else { continue }

                var fullBuckets: [Data: [Candidate]] = [:]
                for candidate in headGroup.sorted(by: { $0.url.path < $1.url.path }) {
                    try Task.checkCancellation()
                    guard Date() < deadline
                    else { return finalize(groups, progress: &progress, onProgress: onProgress) }
                    guard let digest = digest(of: candidate.url, bytes: nil) else { continue }
                    fullBuckets[Data(digest), default: []].append(candidate)
                }

                for (_, identical) in fullBuckets.sorted(by: { $0.key.base64EncodedString() < $1.key.base64EncodedString() }) {
                    guard identical.count > 1 else { continue }
                    let keeperFirst = identical.sorted { lhs, rhs in
                        let lhsDate = lhs.modified ?? Date.distantPast
                        let rhsDate = rhs.modified ?? Date.distantPast
                        if lhsDate != rhsDate { return lhsDate > rhsDate }
                        return lhs.url.path < rhs.url.path
                    }
                    let wastedBytes = keeperFirst.dropFirst().reduce(Int64(0)) { $0 + $1.size }
                    groups.append(DuplicateGroup(
                        files: keeperFirst.map(\.url),
                        totalWastedBytes: wastedBytes
                    ))
                    progress = DuplicateProgress(
                        filesExamined: progress.filesExamined,
                        bytesExamined: progress.bytesExamined,
                        duplicateGroupsFound: groups.count
                    )
                    onProgress(progress)
                }
            }
        }

        return finalize(groups, progress: &progress, onProgress: onProgress)
    }

    // MARK: - Walk

    struct Candidate: Sendable {
        let url: URL
        let size: Int64
        /// Modification time from the walk; nil means "unknown" — an unknown
        /// mtime never wins the keeper race.
        let modified: Date?
    }

    /// Iterative frontier walk with blocked-subtree pruning, per-directory
    /// cancellation and a deadline checked after each directory — an
    /// exhausted budget still yields the roots' direct files, mirroring
    /// `LargeFileScanner`'s deterministic partial results.
    private func collectCandidates(
        in scope: [URL],
        minimumFileSize: Int64,
        environment: ScanEnvironment?,
        deadline: Date
    ) -> (candidates: [Candidate], hitTimeBudget: Bool) {
        // Home-derived blocked roots prune only when the caller handed us the
        // environment; without it, blocked FRAGMENTS still prune anywhere.
        let prefixes = environment.map { BlockedPaths.canonicalPrefixes(home: $0.home) } ?? []
        let fragments = BlockedPaths.blockedFragments

        var candidates: [Candidate] = []
        var hitTimeBudget = false
        // Each scope root starts at its own depth 0 with a canonical spelling
        // so blocked-prefix comparisons stay on one spelling per tree.
        var frontier: [(url: URL, canonical: String)] = scope.map {
            ($0, PathNormalizer.canonicalized($0).path)
        }

        while let (directory, canonical) = frontier.popLast() {
            if Task.isCancelled { break }
            let children: [URL]
            do {
                children = try FileSystemWalker().children(of: directory)
            } catch {
                continue // unreadable: skip, never abort the walk
            }

            for child in children {
                let childCanonical = canonical + "/" + child.lastPathComponent
                if BlockedPaths.isBlocked(childCanonical, prefixes: prefixes, fragments: fragments) {
                    continue
                }
                guard let values = try? child.resourceValues(forKeys: FileSystemWalker.resourceKeySet)
                else { continue }
                if values.isSymbolicLink == true { continue } // I7: never follow, never count
                if values.isDirectory == true {
                    frontier.append((child, childCanonical))
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let size = Int64(values.fileSize ?? 0) // logical: equality key, not allocation
                guard size >= minimumFileSize, size > 0 else { continue }
                candidates.append(Candidate(
                    url: child,
                    size: size,
                    modified: values.contentModificationDate
                ))
            }

            if Date() >= deadline {
                hitTimeBudget = true
                break
            }
        }
        return (candidates, hitTimeBudget)
    }

    // MARK: - Hashing

    /// SHA-256 of the first `bytes` bytes (head hash), or of the whole file
    /// when `bytes` is nil. An unreadable file yields nil — it is skipped,
    /// never fatal.
    private func digest(of url: URL, bytes: Int?) -> SHA256Digest? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return nil
        }
        defer { try? handle.close() }

        do {
            if let bytes {
                guard bytes > 0,
                      let head = try handle.read(upToCount: bytes), !head.isEmpty
                else { return nil }
                return SHA256.hash(data: head)
            }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: Self.hashChunkBytes) {
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize()
        } catch {
            return nil
        }
    }

    // MARK: - Output

    /// Largest waste first; ties break on the keeper's path so the order is
    /// stable across runs.
    private func finalize(
        _ groups: [DuplicateGroup],
        progress: inout DuplicateProgress,
        onProgress: @escaping @Sendable (DuplicateProgress) -> Void
    ) -> [DuplicateGroup] {
        let ordered = groups.sorted { lhs, rhs in
            if lhs.totalWastedBytes != rhs.totalWastedBytes {
                return lhs.totalWastedBytes > rhs.totalWastedBytes
            }
            return (lhs.files.first?.path ?? "") < (rhs.files.first?.path ?? "")
        }
        if ordered.count != progress.duplicateGroupsFound {
            progress = DuplicateProgress(
                filesExamined: progress.filesExamined,
                bytesExamined: progress.bytesExamined,
                duplicateGroupsFound: ordered.count
            )
            onProgress(progress)
        }
        return ordered
    }
}
