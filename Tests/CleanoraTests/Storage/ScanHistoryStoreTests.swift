import XCTest
@testable import Cleanora

/// ScanHistoryStore (tasks T-02/T-03): last-scan persistence + cleanup
/// history with append-trim, day grouping, and corrupt-file recovery.
final class ScanHistoryStoreTests: TempHomeTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
    }

    private func makeStore() -> ScanHistoryStore {
        ScanHistoryStore(directory: directory)
    }

    private func makeResult(bytes: Int64 = 1234) -> ScanResult {
        let item = CleanupItem(
            name: "Chrome Cache",
            category: .browserCaches,
            path: URL(fileURLWithPath: "/tmp/chrome"),
            size: bytes,
            riskLevel: .safe,
            reason: "test",
            deletionMethod: .removeContents
        )
        return ScanResult(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 140),
            items: [item]
        )
    }

    private func makeEntry(
        date: Date,
        bytes: Int64 = 100,
        schemaVersion: Int = CleanupHistoryEntry.schemaVersion
    ) -> CleanupHistoryEntry {
        CleanupHistoryEntry(
            schemaVersion: schemaVersion,
            id: UUID(),
            date: date,
            bytesFreed: bytes,
            itemsRemoved: 2,
            duration: 3,
            categoryTotals: [.init(category: .applicationCaches, bytes: bytes)],
            appVersion: "0.1.0"
        )
    }

    private func historyURL() -> URL {
        directory.appendingPathComponent("history.json")
    }

    // MARK: - Last scan

    func testLastScanRoundTrip() throws {
        let store = makeStore()
        let result = makeResult()
        store.saveLastScan(result)

        XCTAssertEqual(store.lastScan(), result)
    }

    func testLastScanMissingReturnsNil() {
        XCTAssertNil(makeStore().lastScan())
    }

    func testLastScanCorruptReturnsNilThenNextSaveRecovers() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("}{ not json".utf8).write(to: directory.appendingPathComponent("lastscan.json"))

        XCTAssertNil(store.lastScan())

        let result = makeResult()
        store.saveLastScan(result)
        XCTAssertEqual(store.lastScan(), result)
    }

    // MARK: - History

    func testAppendAndReadHistoryNewestFirst() {
        let store = makeStore()
        let oldest = makeEntry(date: Date(timeIntervalSince1970: 1_000))
        let middle = makeEntry(date: Date(timeIntervalSince1970: 2_000))
        let newest = makeEntry(date: Date(timeIntervalSince1970: 3_000))
        store.appendHistory(oldest)
        store.appendHistory(middle)
        store.appendHistory(newest)

        XCTAssertEqual(store.history(), [newest, middle, oldest])
    }

    func testHistoryTrimmedToOneHundredNewestKept() {
        let store = makeStore()
        for index in 0..<120 {
            store.appendHistory(makeEntry(date: Date(timeIntervalSince1970: Double(index))))
        }

        let entries = store.history()
        XCTAssertEqual(entries.count, 100)
        XCTAssertEqual(entries.first?.date.timeIntervalSince1970, 119,
                       "newest entry kept")
        XCTAssertEqual(entries.last?.date.timeIntervalSince1970, 20,
                       "oldest 20 trimmed")
    }

    func testHistoryLimitParameter() {
        let store = makeStore()
        for index in 0..<5 {
            store.appendHistory(makeEntry(date: Date(timeIntervalSince1970: Double(index))))
        }

        XCTAssertEqual(store.history(limit: 2).count, 2)
        XCTAssertEqual(store.history(limit: 2).first?.date.timeIntervalSince1970, 4)
    }

    func testCorruptHistoryRecoversOnNextAppend() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{{{".utf8).write(to: historyURL())

        let entry = makeEntry(date: Date(timeIntervalSince1970: 42))
        store.appendHistory(entry)

        XCTAssertEqual(store.history(), [entry])
    }

    // MARK: - Clear (P-11 History screen)

    // "Clear History" removes the entries only: the last scan is dashboard
    // state, not history, and must survive the clear.
    func testClearHistoryRemovesAllEntriesButKeepsLastScan() {
        let store = makeStore()
        let result = makeResult()
        store.saveLastScan(result)
        store.appendHistory(makeEntry(date: Date(timeIntervalSince1970: 1)))
        store.appendHistory(makeEntry(date: Date(timeIntervalSince1970: 2)))

        store.clearHistory()

        XCTAssertEqual(store.history(), [])
        XCTAssertEqual(store.lastScan(), result)
    }

    func testClearHistoryEmptiesDayGrouping() {
        let store = makeStore()
        store.appendHistory(makeEntry(date: Date(timeIntervalSince1970: 1)))

        store.clearHistory()

        XCTAssertTrue(store.historyGroupedByDay().isEmpty)
    }

    func testClearHistoryThenAppendStartsFresh() {
        let store = makeStore()
        store.appendHistory(makeEntry(date: Date(timeIntervalSince1970: 1)))
        store.clearHistory()

        let entry = makeEntry(date: Date(timeIntervalSince1970: 2))
        store.appendHistory(entry)

        XCTAssertEqual(store.history(), [entry])
    }

    // Clearing with no history file on disk is a harmless no-op.
    func testClearHistoryWithoutHistoryFileIsHarmless() {
        XCTAssertNoThrow(makeStore().clearHistory())
        XCTAssertEqual(makeStore().history(), [])
    }

    func testSchemaVersionSurvivesRoundTrip() {
        let store = makeStore()
        let entry = makeEntry(date: Date(timeIntervalSince1970: 42))
        store.appendHistory(entry)

        XCTAssertEqual(store.history().first?.schemaVersion, CleanupHistoryEntry.schemaVersion)
    }

    // Entries written by a FUTURE schema are unreadable garbage to this
    // version — dropped instead of displayed wrong.
    func testFutureSchemaVersionEntriesAreDropped() {
        let store = makeStore()
        store.appendHistory(makeEntry(date: Date(timeIntervalSince1970: 42)))
        store.appendHistory(makeEntry(date: Date(timeIntervalSince1970: 43), schemaVersion: 99))

        XCTAssertEqual(store.history().count, 1)
        XCTAssertEqual(store.history().first?.schemaVersion, CleanupHistoryEntry.schemaVersion)
    }

    // MARK: - Schema migration (P-12)

    // The migration hook upgrades an OLDER stamp to the current schema one
    // step at a time, preserving every payload field.
    func testMigrateHookUpgradesV0EntryToCurrentVersion() throws {
        let v0 = makeEntry(date: Date(timeIntervalSince1970: 1_234), bytes: 777, schemaVersion: 0)

        let migrated = try XCTUnwrap(ScanHistoryStore.migrate(v0))

        XCTAssertEqual(migrated.schemaVersion, CleanupHistoryEntry.schemaVersion)
        XCTAssertEqual(migrated.id, v0.id)
        XCTAssertEqual(migrated.date, v0.date)
        XCTAssertEqual(migrated.bytesFreed, 777)
        XCTAssertEqual(migrated.itemsRemoved, v0.itemsRemoved)
        XCTAssertEqual(migrated.duration, v0.duration)
        XCTAssertEqual(migrated.categoryTotals, v0.categoryTotals)
        XCTAssertEqual(migrated.appVersion, v0.appVersion)
    }

    // Migration is idempotent: a current-version entry passes through.
    func testMigrateHookLeavesCurrentVersionEntryUnchanged() {
        let current = makeEntry(date: Date(timeIntervalSince1970: 1_234))

        XCTAssertEqual(ScanHistoryStore.migrate(current), current)
    }

    // A FUTURE stamp has no forward path — the hook drops it (the caller
    // logs), so it can never be displayed wrong.
    func testMigrateHookDropsFutureVersionEntry() {
        let future = makeEntry(date: Date(timeIntervalSince1970: 1_234), schemaVersion: 99)

        XCTAssertNil(ScanHistoryStore.migrate(future))
    }

    // End to end: a synthetic v0 entry on disk is served migrated, and the
    // next append rewrites the file so the stamp converges to current.
    func testPersistedV0EntryReadMigratedAndConvergesOnNextAppend() throws {
        let store = makeStore()
        let v0 = makeEntry(date: Date(timeIntervalSince1970: 500), bytes: 555, schemaVersion: 0)
        store.appendHistory(v0)

        let read = try XCTUnwrap(store.history().first)
        XCTAssertEqual(read.schemaVersion, CleanupHistoryEntry.schemaVersion)
        XCTAssertEqual(read.id, v0.id)
        XCTAssertEqual(read.bytesFreed, 555)

        store.appendHistory(makeEntry(date: Date(timeIntervalSince1970: 600)))
        let reread = ScanHistoryStore(directory: directory).history()
        XCTAssertEqual(reread.count, 2)
        XCTAssertTrue(reread.allSatisfy { $0.schemaVersion == CleanupHistoryEntry.schemaVersion },
                      "persisted file converged to the current schema")
    }

    // MARK: - Rotation (P-12)

    func testAppending150EntriesTrimsToMaxHistoryEntriesKeepingNewest() {
        let store = makeStore()
        for index in 0..<150 {
            store.appendHistory(makeEntry(date: Date(timeIntervalSince1970: Double(index))))
        }

        let entries = store.history()
        XCTAssertEqual(entries.count, ScanHistoryStore.maxHistoryEntries)
        XCTAssertEqual(entries.first?.date.timeIntervalSince1970, 149,
                       "newest entry kept")
        XCTAssertEqual(entries.last?.date.timeIntervalSince1970, 50,
                       "oldest 50 trimmed")
    }

    // MARK: - Corruption recovery (P-12)

    // A write interrupted mid-record (crash, disk full) leaves a truncated
    // array. The store must neither crash nor surface garbage: it recovers
    // to the readable prefix — with whole-file JSON that is the empty set —
    // and the next append rebuilds a healthy file.
    func testTruncatedHistoryJSONRecoversToReadablePrefixWithoutCrashing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let complete = String(
            data: try encoder.encode(makeEntry(date: Date(timeIntervalSince1970: 10))),
            encoding: .utf8
        )!
        try Data("[\(complete),\n{\"schemaVersion\":1,\"i".utf8).write(to: historyURL())

        let store = makeStore()
        let recovered = store.history()
        XCTAssertLessThanOrEqual(recovered.count, 1,
                                 "at most the single readable prefix record")
        XCTAssertTrue(recovered.allSatisfy { $0.schemaVersion <= CleanupHistoryEntry.schemaVersion })

        let entry = makeEntry(date: Date(timeIntervalSince1970: 20))
        store.appendHistory(entry)
        XCTAssertEqual(store.history().count, recovered.count + 1)
        XCTAssertEqual(store.history().last?.id, entry.id)
    }

    // Truncated last-scan file behaves like any other corruption: nil.
    func testTruncatedLastScanJSONReturnsNil() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"startedAt\":\"2026-09-12T10:00:00Z\",\"it".utf8)
            .write(to: directory.appendingPathComponent("lastscan.json"))

        XCTAssertNil(makeStore().lastScan())
    }

    // MARK: - Scheduled cleanup (M-02)

    // Scheduled runs write the same entry shape as interactive runs (the
    // schema stays at 1): an entry built from a small report must round-trip
    // through the file, Clear History, and a re-append untouched.
    func testScheduledStyleEntryFromReportRoundTripsThroughClearAndAppend() {
        let store = makeStore()
        let item = CleanupItem(
            name: "Scheduled App Cache",
            category: .applicationCaches,
            path: URL(fileURLWithPath: "/tmp/cleanora-scheduled/cache"),
            size: 4096,
            riskLevel: .safe,
            reason: "test",
            deletionMethod: .removeContents
        )
        let report = CleanupReport(
            startedAt: Date(timeIntervalSince1970: 1_000),
            finishedAt: Date(timeIntervalSince1970: 1_005),
            outcomes: [
                ItemOutcome(
                    itemID: item.id, name: item.name, category: item.category,
                    path: item.path.path, status: .removed, bytesFreed: 4096
                ),
            ],
            freeSpaceBefore: nil,
            freeSpaceAfter: nil,
            scanResultID: UUID()
        )
        let entry = CleanupHistoryEntry(from: report, appVersion: "0.1.0")

        store.appendHistory(entry)
        XCTAssertEqual(store.history(), [entry])
        XCTAssertEqual(
            store.history().first?.schemaVersion, CleanupHistoryEntry.schemaVersion
        )

        store.clearHistory()
        XCTAssertTrue(store.history().isEmpty)

        store.appendHistory(entry)
        XCTAssertEqual(store.history(), [entry])
        XCTAssertEqual(store.history().first?.bytesFreed, 4096)
        XCTAssertEqual(store.history().first?.categoryTotals.first?.category, .applicationCaches)
    }

    // MARK: - Day grouping (History UI)

    func testHistoryGroupedByDayNewestDayFirstEntriesNewestFirst() {
        let store = makeStore()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!

        let todayMorning = makeEntry(date: today.addingTimeInterval(3600), bytes: 100)
        let todayEvening = makeEntry(date: today.addingTimeInterval(7200), bytes: 200)
        let yesterdayEntry = makeEntry(date: yesterday.addingTimeInterval(3600), bytes: 300)
        let olderEntry = makeEntry(date: threeDaysAgo.addingTimeInterval(3600), bytes: 400)

        store.appendHistory(todayMorning)
        store.appendHistory(yesterdayEntry)
        store.appendHistory(todayEvening)
        store.appendHistory(olderEntry)

        let groups = store.historyGroupedByDay()

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].day, today)
        XCTAssertEqual(groups[0].entries.map(\.id), [todayEvening.id, todayMorning.id],
                       "within a day, newest first")
        XCTAssertEqual(groups[0].entries.reduce(Int64(0)) { $0 + $1.bytesFreed }, 300)
        XCTAssertEqual(groups[1].day, calendar.startOfDay(for: yesterday))
        XCTAssertEqual(groups[1].entries.map(\.bytesFreed), [300])
        XCTAssertEqual(groups[2].day, calendar.startOfDay(for: threeDaysAgo))
    }
}
