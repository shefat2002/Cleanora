import XCTest
@testable import Cleanora

private struct SampleRecord: Codable, Equatable {
    var name: String
    var date: Date
}

final class JSONFileStoreTests: TempHomeTestCase {
    private var storeURL: URL {
        tempRoot.appendingPathComponent("store.json")
    }

    func testRoundTrip() throws {
        let store = JSONFileStore<SampleRecord>(url: storeURL)
        let record = SampleRecord(name: "cleanora", date: Date(timeIntervalSince1970: 42))
        try store.write(record)
        XCTAssertEqual(try store.read(), record)
    }

    func testMissingFileReturnsNil() throws {
        let store = JSONFileStore<SampleRecord>(url: storeURL)
        XCTAssertNil(try store.read())
    }

    func testCorruptFileReturnsNilNotThrow() throws {
        try Data("not json {{{".utf8).write(to: storeURL)
        let store = JSONFileStore<SampleRecord>(url: storeURL)
        XCTAssertNil(try store.read())
    }

    func testDateEncodingIsISO8601() throws {
        let store = JSONFileStore<SampleRecord>(url: storeURL)
        try store.write(SampleRecord(name: "x", date: Date(timeIntervalSince1970: 0)))
        let raw = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("1970-01-01"), "dates must be human-readable ISO 8601")
    }

    func testWriteIsAtomic() throws {
        let store = JSONFileStore<SampleRecord>(url: storeURL)
        try store.write(SampleRecord(name: "a", date: Date()))
        try store.write(SampleRecord(name: "b", date: Date()))
        let record = try store.read()
        XCTAssertEqual(record?.name, "b")
        let leftovers = try FileManager.default.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)
        XCTAssertFalse(leftovers.contains { $0.lastPathComponent.contains("tmp") },
                       "atomic write must not leave temp files")
    }
}
