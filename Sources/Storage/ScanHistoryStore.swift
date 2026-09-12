import Foundation
import os

/// Persists the last scan (Dashboard) and cleanup history (History screen).
/// Versioned JSON via JSONFileStore; corrupt or missing files recover to
/// empty (a bad history file must never crash the app or block a cleanup).
public struct ScanHistoryStore: Sendable {
    private static let log = Logger(subsystem: "com.cleanora.app", category: "storage")

    public static let maxHistoryEntries = 100

    private let lastScanFile: JSONFileStore<ScanResult>
    private let historyFile: JSONFileStore<[CleanupHistoryEntry]>

    /// `directory` is Cleanora's Application Support directory.
    public init(directory: URL) {
        self.lastScanFile = JSONFileStore<ScanResult>(
            url: directory.appendingPathComponent("lastscan.json")
        )
        self.historyFile = JSONFileStore<[CleanupHistoryEntry]>(
            url: directory.appendingPathComponent("history.json")
        )
    }

    public func saveLastScan(_ result: ScanResult) {
        do {
            try lastScanFile.write(result)
        } catch {
            // Persistence must never fail the scan flow; the next save retries.
            Self.log.error("last-scan save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func lastScan() -> ScanResult? {
        (try? lastScanFile.read()) ?? nil
    }

    /// Append + sort newest-first + trim to `maxHistoryEntries`.
    public func appendHistory(_ entry: CleanupHistoryEntry) {
        var entries = readableHistory()
        entries.append(entry)
        entries.sort { $0.date > $1.date }
        if entries.count > Self.maxHistoryEntries {
            entries.removeLast(entries.count - Self.maxHistoryEntries)
        }
        do {
            try historyFile.write(entries)
        } catch {
            Self.log.error("history save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func history(limit: Int = 100) -> [CleanupHistoryEntry] {
        Array(readableHistory().prefix(max(0, limit)))
    }

    /// Removes every history entry (History screen "Clear History"). The
    /// last scan is deliberately kept — it is dashboard state, not history.
    /// Persistence failures are logged, never thrown.
    public func clearHistory() {
        do {
            try historyFile.write([])
        } catch {
            Self.log.error("history clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Day-grouped history for the History screen: newest day first, entries
    /// within a day newest first.
    public func historyGroupedByDay() -> [(day: Date, entries: [CleanupHistoryEntry])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [CleanupHistoryEntry]] = [:]
        for entry in readableHistory() {
            let day = calendar.startOfDay(for: entry.date)
            if byDay[day] == nil {
                order.append(day)
            }
            byDay[day, default: []].append(entry)
        }
        return order.map { (day: $0, entries: byDay[$0] ?? []) }
    }

    /// Versioned migration policy (P-12).
    ///
    /// - Entries stamped by the CURRENT schema pass through unchanged.
    /// - Entries stamped by an OLDER schema upgrade forward one step at a
    ///   time via `migrationSteps`. `appendHistory` rewrites the whole file
    ///   from migrated entries, so the persisted stamp converges to current
    ///   on the next write.
    /// - Entries stamped by a FUTURE schema (or an older version with no
    ///   migration path) return nil and are logged: this build cannot know
    ///   how to read them, so displaying them would be wrong.
    static func migrate(_ entry: CleanupHistoryEntry) -> CleanupHistoryEntry? {
        var migrated = entry
        while migrated.schemaVersion < CleanupHistoryEntry.schemaVersion {
            guard let step = migrationSteps[migrated.schemaVersion] else {
                log.error(
                    "history: no migration from schema \(migrated.schemaVersion, privacy: .public); entry dropped"
                )
                return nil
            }
            let upgraded = step(migrated)
            guard upgraded.schemaVersion > migrated.schemaVersion else {
                log.error(
                    "history: migration step \(migrated.schemaVersion, privacy: .public) does not advance; entry dropped"
                )
                return nil
            }
            migrated = upgraded
        }
        guard migrated.schemaVersion == CleanupHistoryEntry.schemaVersion else {
            log.error(
                "history: future schema \(migrated.schemaVersion, privacy: .public) entry dropped"
            )
            return nil
        }
        return migrated
    }

    /// One-step upgrades, keyed by the version being upgraded FROM. Bump
    /// `CleanupHistoryEntry.schemaVersion` and add its N → N+1 step here in
    /// the same change.
    private static let migrationSteps: [Int: @Sendable (CleanupHistoryEntry) -> CleanupHistoryEntry] = [
        // v0 → v1: the pre-release stamp. Fields already match v1; re-stamp.
        0: { entry in
            CleanupHistoryEntry(
                schemaVersion: 1,
                id: entry.id,
                date: entry.date,
                bytesFreed: entry.bytesFreed,
                itemsRemoved: entry.itemsRemoved,
                duration: entry.duration,
                categoryTotals: entry.categoryTotals,
                appVersion: entry.appVersion
            )
        },
    ]

    /// Tolerant read: corrupt file → empty; entries migrate per
    /// `migrate(_:)` — older forward, future dropped (and logged).
    private func readableHistory() -> [CleanupHistoryEntry] {
        let entries = (try? historyFile.read()) ?? []
        return entries
            .compactMap { Self.migrate($0) }
            .sorted { $0.date > $1.date }
    }
}
