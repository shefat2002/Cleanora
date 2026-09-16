import Foundation
import Observation

/// Dashboard state: health headline, safe-to-clean total, last-scan line and
/// per-category sizes. All decision logic is pure and static; the instance
/// only caches what `refresh()` loaded from the injected providers.
@MainActor
@Observable
final class DashboardViewModel {
    struct CategoryRow: Identifiable, Equatable {
        let category: ScanCategory
        let bytes: Int64
        var id: String { category.rawValue }
    }

    /// One stacked-bar segment for the disk overview (P-10). `startBytes` is
    /// precomputed so the chart renders deterministic intervals and the
    /// layout itself stays pure and testable.
    struct DiskSegment: Identifiable, Equatable {
        enum Kind: Equatable {
            case junk(ScanCategory)
            case otherUsed
            case free
        }

        let kind: Kind
        let bytes: Int64
        let startBytes: Int64
        var endBytes: Int64 { startBytes + bytes }
        let label: String
        var id: String { label }
    }

    private(set) var lastScan: ScanResult?
    private(set) var diskOverview: DiskOverview?
    private(set) var hasFullDiskAccess = true
    private(set) var didLoad = false

    var hasScan: Bool { lastScan != nil }
    var safeToCleanBytes: Int64 { Self.safeToCleanBytes(for: lastScan) }
    var headline: String {
        Self.healthHeadline(for: safeToCleanBytes, hasScan: hasScan)
    }
    var freeSpaceLine: String? { Self.freeSpaceLine(for: diskOverview) }
    var categoryRows: [CategoryRow] { Self.categoryRows(for: lastScan) }

    private let loadLastScan: @MainActor () -> ScanResult?
    private let loadDiskOverview: @MainActor () -> DiskOverview?
    private let permissionCheck: @MainActor () -> Bool

    init(
        loadLastScan: @escaping @MainActor () -> ScanResult?,
        loadDiskOverview: @escaping @MainActor () -> DiskOverview?,
        permissionCheck: @escaping @MainActor () -> Bool
    ) {
        self.loadLastScan = loadLastScan
        self.loadDiskOverview = loadDiskOverview
        self.permissionCheck = permissionCheck
    }

    convenience init(environment: AppEnvironment) {
        self.init(
            loadLastScan: { environment.lastScanResult ?? environment.scanHistoryStore.lastScan() },
            loadDiskOverview: { DiskInfoProvider().overview() },
            permissionCheck: { environment.hasFullDiskAccess() }
        )
    }

    func refresh(
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        if let stored = loadLastScan() {
            // Keep whichever scan is newer — a fresh in-memory scan beats a
            // reloaded store entry from launch.
            if lastScan == nil || stored.finishedAt > (lastScan?.finishedAt ?? .distantPast) {
                lastScan = stored
            }
        }
        diskOverview = loadDiskOverview()
        hasFullDiskAccess = permissionCheck()
        didLoad = true
        lastRefreshedAt = now
        lastScanLine = Self.lastScanLine(
            for: lastScan?.finishedAt,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
    }

    /// Formatted during refresh (with the refresh-time clock) rather than in
    /// body, so the line is stable while the view is visible.
    private(set) var lastScanLine: String?
    private var lastRefreshedAt: Date?

    // MARK: - Pure logic

    /// Preselected bytes = everything marked `.safe`. A misbehaving result
    /// with empty summaries still yields a number because this reads items.
    static func safeToCleanBytes(for result: ScanResult?) -> Int64 {
        guard let result else { return 0 }
        return result.items
            .filter { $0.riskLevel == .safe }
            .reduce(0) { $0 + $1.size }
    }

    static func categoryRows(for result: ScanResult?) -> [CategoryRow] {
        guard let result else { return [] }
        return ScanCategory.scanOrder.compactMap { category in
            let bytes = result.items(in: category).reduce(Int64(0)) { $0 + $1.size }
            guard bytes > 0 else { return nil }
            return CategoryRow(category: category, bytes: bytes)
        }
    }

    /// P-10: one part-to-whole bar — cleanable junk per category, then the
    /// rest of the used space, then free space. Junk is measured from the
    /// last scan (0 when none), used/free from the disk probe, so the
    /// placeholder case is a used/free-only bar.
    static func diskSegments(scan: ScanResult?, overview: DiskOverview?) -> [DiskSegment] {
        guard let overview, overview.totalCapacity > 0 else { return [] }
        var segments: [DiskSegment] = []
        var cursor: Int64 = 0
        for row in categoryRows(for: scan) {
            segments.append(DiskSegment(
                kind: .junk(row.category),
                bytes: row.bytes,
                startBytes: cursor,
                label: "\(row.category.displayName) (cleanable)"
            ))
            cursor += row.bytes
        }
        let used = max(0, overview.usedBytes - cursor)
        if used > 0 {
            segments.append(DiskSegment(
                kind: .otherUsed,
                bytes: used,
                startBytes: cursor,
                label: "Used space"
            ))
            cursor += used
        }
        if overview.availableForImportantUsage > 0 {
            segments.append(DiskSegment(
                kind: .free,
                bytes: overview.availableForImportantUsage,
                startBytes: cursor,
                label: "Free space"
            ))
        }
        return segments
    }

    /// Spoken summary for the whole chart, so VoiceOver gets one sentence
    /// instead of relying on mark order.
    static func diskSummaryLine(for overview: DiskOverview?, scan: ScanResult?) -> String? {
        guard let overview else { return nil }
        let junk = categoryRows(for: scan).reduce(Int64(0)) { $0 + $1.bytes }
        let base = "\(overview.availableForImportantUsage.formattedByteCount) free of " +
            "\(overview.totalCapacity.formattedByteCount)"
        guard junk > 0 else { return base }
        return "\(base), \(junk.formattedByteCount) cleanable"
    }

    /// Health copy. Measured, never alarming: the worst phrase is "needs
    /// attention", and thresholds are absolute gigabyte steps.
    static func healthHeadline(for safeBytes: Int64, hasScan: Bool) -> String {
        guard hasScan else { return "Ready" }
        let fiveGB: Int64 = 5_000_000_000
        let twentyFiveGB: Int64 = 25_000_000_000
        if safeBytes < fiveGB { return "Healthy" }
        if safeBytes < twentyFiveGB { return "Could be cleaner" }
        return "Needs attention"
    }

    /// First-run explainer. Factual only: no promised byte amounts
    /// (measured-bytes rule), no alarm copy, no second CTA.
    nonisolated static let firstRunTitle = "Cleanora finds files you can safely delete."
    nonisolated static let firstRunPoints: [String] = [
        "Scanning only reads your Mac — nothing is deleted or moved.",
        "You review every item first. Items marked “Review” stay unselected.",
        "Cleaning always shows exactly what will be removed before it starts.",
    ]

    static func freeSpaceLine(for overview: DiskOverview?) -> String? {
        guard let overview else { return nil }
        return "\(overview.availableForImportantUsage.formattedByteCount) available"
    }

    /// "Last scan: Today, 10:42 AM" — nil until a scan exists.
    static func lastScanLine(
        for date: Date?,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> String? {
        guard let date else { return nil }
        return "Last scan: " + DateFormatting.timestampLine(
            for: date,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
    }
}
