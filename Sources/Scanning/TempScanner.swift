import Foundation

/// C-04 — stale temporary files and directories.
///
/// Roots: the injected `environment.temporaryRoot` plus the system-shared
/// `/private/tmp` (entries owned by the current user only — other users' files
/// are never even reported). Entries modified within the last 24 hours are
/// skipped: they may be in active use.
public struct TempScanner: Scanner {
    public let category: ScanCategory = .temporaryFiles
    public let progressKey: ScannerKey
    public let isPhaseOne: Bool = true
    /// The system-wide shared temp directory. Injectable for fixtures.
    public let sharedTempRoot: URL

    /// Entries newer than this are considered live and skipped (24 hours).
    public static let stalenessCutoff: TimeInterval = 24 * 60 * 60

    public init(
        sharedTempRoot: URL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    ) {
        self.sharedTempRoot = sharedTempRoot
        self.progressKey = ScannerKey(id: .temporaryFiles)
    }

    public func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome {
        let roots = [environment.temporaryRoot, sharedTempRoot]
        if let reason = ScannerGuards.skipReason(roots: roots, environment: environment) {
            return .skipped(reason)
        }
        guard !Task.isCancelled else { return .produced([]) }
        onProgress(progressKey, .running(bytesScanned: 0, itemsFound: 0))

        let walker = FileSystemWalker()
        let calculator = DirectorySizeCalculator()
        var items: [CleanupItem] = []
        var discoveredBytes: Int64 = 0

        for root in roots {
            if Task.isCancelled { break }
            guard environment.exists(root), environment.readable(root) else { continue }
            let children = ((try? walker.children(of: root)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for child in children {
                if Task.isCancelled { break }
                let values = try? child.resourceValues(forKeys: FileSystemWalker.resourceKeySet)
                guard values?.isSymbolicLink != true else { continue } // I7 + never report links
                let isDirectory = values?.isDirectory == true
                let isRegularFile = values?.isRegularFile == true
                guard isDirectory || isRegularFile else { continue }
                guard ScannerGuards.isStale(
                    modificationDate: values?.contentModificationDate,
                    olderThan: Self.stalenessCutoff
                ) else { continue }
                guard Self.isOwnedByCurrentUser(ownerID: Self.ownerID(of: child)) else { continue }

                let measurement: DirectorySizeCalculator.Result
                if isDirectory {
                    measurement = await calculator.measure(at: child)
                } else {
                    measurement = DirectorySizeCalculator.Result(
                        bytes: ScannerGuards.fileSize(from: values),
                        fileCount: 1
                    )
                }
                guard measurement.fileCount > 0 else { continue }
                discoveredBytes += measurement.bytes
                onProgress(progressKey, .running(
                    bytesScanned: discoveredBytes, itemsFound: items.count + 1
                ))

                let name = child.lastPathComponent
                items.append(CleanupItem(
                    name: name,
                    appName: nil,
                    category: .temporaryFiles,
                    path: child,
                    size: measurement.bytes,
                    fileCount: measurement.fileCount,
                    riskLevel: .safe,
                    reason: isDirectory
                        ? "\(name) is a stale temporary directory (untouched for over 24 hours); apps recreate temp data on demand."
                        : "\(name) is a stale temporary file (untouched for over 24 hours); apps recreate temp data on demand.",
                    deletionMethod: isDirectory ? .removeContents : .moveToTrash
                ))
            }
        }
        return .produced(items)
    }

    /// POSIX owner of `url`, or nil when it cannot be determined (then it is
    /// treated as NOT ours — never clean on a guess).
    static func ownerID(of url: URL) -> UInt32? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        if let number = attributes[.ownerAccountID] as? NSNumber { return number.uint32Value }
        if let value = attributes[.ownerAccountID] as? UInt32 { return value }
        return nil
    }

    static func isOwnedByCurrentUser(ownerID: UInt32?) -> Bool {
        guard let ownerID else { return false }
        return ownerID == getuid()
    }
}
