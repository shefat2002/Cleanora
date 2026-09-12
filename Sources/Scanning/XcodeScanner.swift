import Foundation

/// P-01 — Xcode developer data: one progress row and one item per root, so
/// the progress screen fans out per tool location instead of one opaque
/// "Developer" line.
///
/// | Root | Risk | Method | Why |
/// |---|---|---|---|
/// | DerivedData | safe | trashDirectory | build products + indexes, regenerated on next build |
/// | Archives | review | trashDirectory | distributed-build archives, only way to re-upload an old build |
/// | iOS DeviceSupport | review | trashDirectory | device symbols, re-fetched on next device connect |
/// | CoreSimulator Caches | safe | removeContents | simulator caches, rebuilt when simulators launch |
///
/// Absent roots are skipped per row (`.pathNotFound`) without failing the
/// scanner. The scanner's own `progressKey` ("Xcode") is coordinator
/// bookkeeping only — it emits just its four row keys.
public struct XcodeScanner: Scanner, ProgressFanOutScanner {
    public let category: ScanCategory = .developerData
    public let progressKey: ScannerKey
    public let isPhaseOne: Bool = false

    struct RowSpec: Sendable {
        let label: String
        let pathComponents: [String]
        let riskLevel: RiskLevel
        let deletionMethod: DeletionMethod
        let reason: String

        func url(in environment: ScanEnvironment) -> URL {
            environment.home.appending(pathComponents)
        }
    }

    static let rowSpecs: [RowSpec] = [
        RowSpec(
            label: "Xcode — DerivedData",
            pathComponents: ["Library", "Developer", "Xcode", "DerivedData"],
            riskLevel: .safe,
            deletionMethod: .trashDirectory,
            reason: "Xcode keeps build products, indexes and module caches for every project here. Xcode regenerates all of it on the next build."
        ),
        RowSpec(
            label: "Xcode — Archives",
            pathComponents: ["Library", "Developer", "Xcode", "Archives"],
            riskLevel: .review,
            deletionMethod: .trashDirectory,
            reason: "Archives are the distributable builds Xcode's Organizer created. Deleting one removes the ability to re-upload or symbolicate that build — check you no longer need them."
        ),
        RowSpec(
            label: "Xcode — iOS DeviceSupport",
            pathComponents: ["Library", "Developer", "Xcode", "iOS DeviceSupport"],
            riskLevel: .review,
            deletionMethod: .trashDirectory,
            reason: "Symbol files pulled from connected iPhone and iPad OS versions. The next time a device with that OS version connects, they are re-fetched (which takes a while)."
        ),
        RowSpec(
            label: "Xcode — CoreSimulator Caches",
            pathComponents: ["Library", "Developer", "CoreSimulator", "Caches"],
            riskLevel: .safe,
            deletionMethod: .removeContents,
            reason: "Simulator runtime caches are rebuilt automatically the next time simulators launch. Simulator devices and their data are not touched."
        ),
    ]

    public init() {
        self.progressKey = ScannerKey(id: .developerData, label: "Xcode")
    }

    public func rowKeys(
        environment: ScanEnvironment,
        options: ScanOptions
    ) -> [ScannerKey] {
        Self.rowSpecs.map { ScannerKey(id: .developerData, label: $0.label) }
    }

    public func scan(
        in environment: ScanEnvironment,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void
    ) async throws -> ScannerOutcome {
        guard !Task.isCancelled else { return .produced([]) }

        let calculator = DirectorySizeCalculator()
        var items: [CleanupItem] = []
        var discoveredBytes: Int64 = 0

        for spec in Self.rowSpecs {
            if Task.isCancelled { break }
            let rowKey = ScannerKey(id: .developerData, label: spec.label)
            let root = spec.url(in: environment)

            guard environment.exists(root) else {
                onProgress(rowKey, .skipped(.pathNotFound(root.path)))
                continue
            }
            guard environment.readable(root) else {
                onProgress(rowKey, .skipped(.permissionDenied(root.path)))
                continue
            }

            let measurement = await calculator.measure(at: root)
            if measurement.fileCount > 0 {
                discoveredBytes += measurement.bytes
                items.append(CleanupItem(
                    name: spec.label,
                    appName: "Xcode",
                    category: .developerData,
                    path: root,
                    size: measurement.bytes,
                    fileCount: measurement.fileCount,
                    riskLevel: spec.riskLevel,
                    reason: spec.reason,
                    deletionMethod: spec.deletionMethod
                ))
            }
            onProgress(rowKey, .completed(
                totalBytes: measurement.bytes, itemCount: measurement.fileCount
            ))
        }
        return .produced(items)
    }
}
