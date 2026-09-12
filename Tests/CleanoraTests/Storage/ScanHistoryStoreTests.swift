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
