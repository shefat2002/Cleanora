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

    /// Tolerant read: corrupt file → empty; entries stamped by a FUTURE
    /// schema are dropped rather than displayed wrong.
    private func readableHistory() -> [CleanupHistoryEntry] {
        let entries = (try? historyFile.read()) ?? []
        return entries
            .filter { $0.schemaVersion <= CleanupHistoryEntry.schemaVersion }
            .sorted { $0.date > $1.date }
    }
}
