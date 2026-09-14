import AppKit
import Foundation
import Observation

/// State for the compact menu bar panel (M-01): free space, junk estimate
/// from the last scan, the last-clean line, and the quick Scan action. All
/// presentation decisions are pure and static; refresh() loads from the
/// injected providers exactly like DashboardViewModel.
@MainActor
@Observable
final class MenuBarPanelViewModel {
    private(set) var freeSpaceLine: String?
    private(set) var junkLine: String?
    private(set) var lastScanLine: String?
    private(set) var lastCleanLine: String?
    private(set) var didLoad = false

    private let loadLastScan: @MainActor () -> ScanResult?
    private let loadDiskOverview: @MainActor () -> DiskOverview?
    private let loadLastCleanupDate: @MainActor () -> Date?
    private let openMainWindowAction: @MainActor () -> Void
    private let startScanAction: @MainActor () -> Void

    init(
        loadLastScan: @escaping @MainActor () -> ScanResult?,
        loadDiskOverview: @escaping @MainActor () -> DiskOverview?,
        loadLastCleanupDate: @escaping @MainActor () -> Date?,
        openMainWindowAction: @escaping @MainActor () -> Void,
        startScanAction: @escaping @MainActor () -> Void
    ) {
        self.loadLastScan = loadLastScan
        self.loadDiskOverview = loadDiskOverview
        self.loadLastCleanupDate = loadLastCleanupDate
        self.openMainWindowAction = openMainWindowAction
        self.startScanAction = startScanAction
    }

    /// Opens the main window (activating the app). The popover-hosted panel
    /// has no scene context, so this routes through the handler CleanoraApp
    /// captured from a scene-hosted view.
    func openMainWindow() {
        openMainWindowAction()
    }

    /// The window opens first so the scan route lands somewhere visible; the
    /// scan itself is the exact flow the dashboard button runs.
    func scanNow() {
        openMainWindowAction()
        startScanAction()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func refresh(
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        let scan = loadLastScan()
        freeSpaceLine = Self.freeSpaceLine(for: loadDiskOverview())
        junkLine = Self.junkLine(junkEstimateBytes: Self.junkEstimateBytes(for: scan), hasScan: scan != nil)
        lastScanLine = Self.lastScanLine(for: scan?.finishedAt, now: now, calendar: calendar, locale: locale, timeZone: timeZone)
        lastCleanLine = Self.lastCleanLine(
            for: loadLastCleanupDate(),
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        didLoad = true
    }

    // MARK: - Pure logic

    /// Every cleanable byte the last scan reported — the panel's honest
    /// "junk" number, identical to the dashboard's found total.
    static func junkEstimateBytes(for result: ScanResult?) -> Int64 {
        guard let result else { return 0 }
        return result.items.reduce(0) { $0 + $1.size }
    }

    static func junkLine(junkEstimateBytes: Int64, hasScan: Bool) -> String {
        guard hasScan else { return "No scan yet" }
        return "\(junkEstimateBytes.formattedByteCount) cleanable"
    }

    static func freeSpaceLine(for overview: DiskOverview?) -> String? {
        guard let overview else { return nil }
        return "\(overview.availableForImportantUsage.formattedByteCount) free"
    }

    static func lastScanLine(
        for date: Date?,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> String? {
        guard let date else { return nil }
        return "Scanned " + DateFormatting.timestampLine(
            for: date,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
    }

    /// "Last cleaned: Today, 5:42 PM"; nil until a cleanup exists in history.
    static func lastCleanLine(
        for date: Date?,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> String? {
        guard let date else { return nil }
        return "Last cleaned: " + DateFormatting.timestampLine(
            for: date,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
    }
}
