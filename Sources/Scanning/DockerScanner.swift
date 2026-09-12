import Foundation

/// P-06 — Docker, with the frozen safety decision baked in:
///
/// Docker Desktop stores images, containers and build cache inside ONE
/// sparse disk image (`…/com.docker.docker/Data/vms/0/data/Docker.raw`).
/// Deleting that file would destroy every image and container, so:
///
/// 1. Docker.raw is measured READ-ONLY. Its path is NEVER an item path.
/// 2. When no verified-safe discrete cache directory exists (the normal
///    case — the standard allowlist is empty by design), the scanner emits a
///    single `.review` INFORMATIONAL item whose path is the container's
///    `Data` directory. That path is deliberately OUTSIDE every SafetyPolicy
///    allowed root, so the cleanup gate rejects it: `docker system prune
///    --force` — stated in the reason — is the only thing that may ever
///    remove the data. Prune EXECUTION is out of scope for the engine; it
///    belongs to the UI confirm flow in a later phase.
/// 3. `.review` + `.moveToTrash` items are produced only for paths on the
///    (injectable) cache allowlist — future verified-safe, regenerable
///    build-cache directories.
/// 4. Neither Docker.raw nor the docker CLI found → `.toolNotInstalled`.
///    CLI present but nothing measurable → completes with zero items rather
///    than inventing a size.
public struct DockerScanner: Scanner {
    public let category: ScanCategory = .developerData
    public let progressKey: ScannerKey
    public let isPhaseOne: Bool = false

    /// The sparse disk image — measured, named in the reason, never deletable.
    static let rawDiskComponents = [
        "Library", "Containers", "com.docker.docker", "Data", "vms", "0", "data", "Docker.raw",
    ]
    /// Marker directory for the informational item: real, always present when
    /// Docker.raw exists, and gate-rejected by SafetyPolicy by construction.
    static let markerComponents = [
        "Library", "Containers", "com.docker.docker", "Data",
    ]
    /// PATH-independent CLI probe locations (GUI apps inherit no shell PATH).
    static let cliProbePaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]

    private let cliDetector: @Sendable () -> Bool
    /// Verified-safe discrete build-cache directories. Docker Desktop keeps
    /// build cache INSIDE Docker.raw, so the standard allowlist is empty; a
    /// path is added only with documented evidence it is regenerable cache.
    private let cachePathAllowlist: [URL]

    public init(
        cliDetector: @escaping @Sendable () -> Bool = Self.defaultCLIDetector,
        cachePathAllowlist: [URL] = []
    ) {
        self.progressKey = ScannerKey(id: .developerData, label: "Docker")
        self.cliDetector = cliDetector
        self.cachePathAllowlist = cachePathAllowlist
    }

    /// File-existence probes only: spawning the docker CLI would boot the VM
    /// and is exactly the side effect a scanner must not have. (`docker
    /// system df` is likewise never run from a scan — measurement stays on
    /// the filesystem.)
    public static func defaultCLIDetector() -> Bool {
        cliProbePaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    public func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome {
        guard !Task.isCancelled else { return .produced([]) }
        onProgress(progressKey, .running(bytesScanned: 0, itemsFound: 0))

        let rawDisk = environment.home.appending(Self.rawDiskComponents)
        let rawDiskExists = environment.exists(rawDisk)
        guard rawDiskExists || cliDetector() else {
            onProgress(progressKey, .skipped(.toolNotInstalled("Docker")))
            return .skipped(.toolNotInstalled("Docker"))
        }
        let rawDiskBytes = rawDiskExists
            ? ScannerGuards.fileSize(
                from: try? rawDisk.resourceValues(forKeys: FileSystemWalker.resourceKeySet)
            )
            : 0

        // Discrete, allowlisted, verified-safe cache directories only.
        let calculator = DirectorySizeCalculator()
        var items: [CleanupItem] = []
        var discoveredBytes: Int64 = 0
        for cache in cachePathAllowlist where environment.exists(cache) {
            if Task.isCancelled { break }
            guard environment.readable(cache) else { continue }
            let measurement = await calculator.measure(at: cache)
            discoveredBytes += measurement.bytes
            onProgress(progressKey, .running(
                bytesScanned: discoveredBytes, itemsFound: items.count + 1
            ))
            items.append(CleanupItem(
                name: "Docker build cache",
                appName: "Docker",
                category: .developerData,
                path: cache,
                size: measurement.bytes,
                fileCount: measurement.fileCount,
                riskLevel: .review,
                reason: "This is a verified Docker build cache directory; the daemon re-creates it as builds run. Removing it discards cached build layers only — images and containers are untouched.",
                deletionMethod: .moveToTrash
            ))
        }
        if !items.isEmpty {
            onProgress(progressKey, .completed(
                totalBytes: discoveredBytes, itemCount: items.count
            ))
            return .produced(items)
        }

        guard rawDiskExists else {
            // CLI present but nothing measurable on this machine (engine on a
            // remote host): complete honestly with zero findings.
            onProgress(progressKey, .completed(totalBytes: 0, itemCount: 0))
            return .produced([])
        }

        // Informational item: measurement only. Its path is the container's
        // Data directory — never Docker.raw, never inside any allowed root,
        // so the cleanup gate always rejects it. The reason states exactly
        // what the real cleanup would do.
        let marker = environment.home.appending(Self.markerComponents)
        onProgress(progressKey, .completed(
            totalBytes: rawDiskBytes, itemCount: 1
        ))
        return .produced([CleanupItem(
            name: "Docker build cache",
            appName: "Docker",
            category: .developerData,
            path: marker,
            size: rawDiskBytes,
            fileCount: nil,
            riskLevel: .review,
            reason: "Docker Desktop keeps images, containers and build cache inside a single disk image (Docker.raw, currently \(rawDiskBytes.formattedByteCount)). Cleanora never deletes that file — doing so would destroy all containers and images. Instead, cleaning this entry runs `docker system prune --force`, which removes unused build cache, stopped containers and dangling images. This row is informational: the prune command runs only from Cleanora's confirm dialog, never by trashing this path.",
            deletionMethod: .moveToTrash
        )])
    }
}
