import Foundation
import os

public enum LogEntry: Equatable, Codable, Sendable {
    case attempt(itemID: UUID, name: String, path: String, date: Date)
    case result(itemID: UUID, status: ItemOutcome.Status, bytesFreed: Int64, date: Date)
}

/// Write-ahead cleanup logger (invariant I9): the attempt record is on disk
/// — fsynced — BEFORE the destructive call, the result after. One JSONL
/// entry per line, one file per day in Cleanora's own Logs directory (which
/// SafetyPolicy excludes from cleaning — I10).
///
/// `@unchecked Sendable` because the logger is shared between the cleanup
/// task and log readers; soundness comes from `lock`, which guards the
/// current-file cache and serializes every append and read.
public final class CleanupLogger: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.cleanora.app", category: "cleanup-log")

    private let appDirs: AppDirectories
    private let clock: @Sendable () -> Date
    private let calendar = Calendar.current
    // Formatters are not thread-safe; both are used only under `lock`.
    private let timestampFormatter = ISO8601DateFormatter()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private var currentDay: Date?
    private var currentLogFilePath: URL?

    public convenience init(appDirs: AppDirectories) {
        self.init(appDirs: appDirs, clock: { Date() })
    }

    /// Test seam: injectable clock for day-rollover behavior.
    init(appDirs: AppDirectories, clock: @escaping @Sendable () -> Date) {
        self.appDirs = appDirs
        self.clock = clock
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func appendAttempt(_ item: CleanupItem) {
        _ = attemptRecord(item)
    }

    public func appendResult(_ outcome: ItemOutcome) {
        _ = append(
            entry: .result(
                itemID: outcome.itemID,
                status: outcome.status,
                bytesFreed: outcome.bytesFreed,
                date: clock()
            )
        )
    }

    /// Internal: appendAttempt that reports whether the record is durable on
    /// disk. CleanupExecutor refuses to delete an item whose WAL write
    /// failed — no attempt on disk, no deletion.
    func attemptRecord(_ item: CleanupItem) -> Bool {
        append(
            entry: .attempt(
                itemID: item.id,
                name: item.name,
                path: item.path.path,
                date: clock()
            )
        )
    }

    /// Tolerant read of today's file: corrupt lines are skipped, not fatal.
    public func readCurrentLog() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let url = todaysFileLocked(create: false),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(LogEntry.self, from: data)
            }
    }

    public var currentLogURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return todaysFileLocked(create: false)
    }

    // MARK: - Internals (all called under `lock`)

    private func append(entry: LogEntry) -> Bool {
        let data: Data
        // Encode under the lock: JSONEncoder is documented non-thread-safe.
        lock.lock()
        defer { lock.unlock() }
        do {
            data = try encoder.encode(entry)
        } catch {
            Self.log.error("cleanup log: entry not encodable: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard let url = todaysFileLocked(create: true) else { return false }
        return writeDurably(data: data + Data("\n".utf8), to: url)
    }

    /// Append + fsync. An atomic write alone can lose the WAL on power loss
    /// while the deletions it describes persist — synchronizeFile is the
    /// whole point of this journal.
    private func writeDurably(data: Data, to url: URL) -> Bool {
        guard let handle = try? FileHandle(forWritingTo: url) else {
            Self.log.error("cleanup log: cannot open \(url.path, privacy: .public)")
            return false
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            handle.synchronizeFile()
            return true
        } catch {
            Self.log.error("cleanup log: append failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Today's WAL file: the cached one, else a file created earlier today
    /// (a relaunch mid-day keeps appending to the same journal), else new.
    private func todaysFileLocked(create: Bool) -> URL? {
        let now = clock()
        if let url = currentLogFilePath, let day = currentDay,
           calendar.isDate(day, inSameDayAs: now) {
            return url
        }
        if let existing = existingTodaysFile(on: now) {
            currentLogFilePath = existing
            currentDay = now
            return existing
        }
        guard create else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: appDirs.logsDirectory, withIntermediateDirectories: true
            )
        } catch {
            Self.log.error("cleanup log: cannot create logs directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let url = appDirs.logsDirectory
            .appendingPathComponent("cleanup-\(timestamp(now)).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            Self.log.error("cleanup log: cannot create \(url.path, privacy: .public)")
            return nil
        }
        // fsync the directory too, so the new file's directory entry
        // survives a crash before the first write lands.
        if let directoryHandle = try? FileHandle(forReadingFrom: appDirs.logsDirectory) {
            try? directoryHandle.synchronizeFile()
            try? directoryHandle.close()
        }
        currentLogFilePath = url
        currentDay = now
        return url
    }

    private func existingTodaysFile(on day: Date) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: appDirs.logsDirectory, includingPropertiesForKeys: nil, options: []
        ))?
            .filter { isTodaysLogFile($0, on: day) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files?.last
    }

    private func isTodaysLogFile(_ url: URL, on day: Date) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix("cleanup-"), name.hasSuffix(".jsonl") else { return false }
        let stamp = name.dropFirst("cleanup-".count).dropLast(".jsonl".count)
        guard let parsed = timestampFormatter.date(from: String(stamp)) else { return false }
        return calendar.isDate(parsed, inSameDayAs: day)
    }

    private func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }
}
