import XCTest
@testable import Cleanora

/// P-01 — XcodeScanner: separate progress rows and items per Xcode root.
/// Every path is derived from the injected environment home, so the test
/// never assumes Xcode exists on the machine.
final class XcodeScannerTests: TempHomeTestCase {
    private let scanner = XcodeScanner()

    private var derivedData: URL {
        environment.home.appending(["Library", "Developer", "Xcode", "DerivedData"])
    }
    private var archives: URL {
        environment.home.appending(["Library", "Developer", "Xcode", "Archives"])
    }
    private var deviceSupport: URL {
        environment.home.appending(["Library", "Developer", "Xcode", "iOS DeviceSupport"])
    }
    private var simulatorCaches: URL {
        environment.home.appending(["Library", "Developer", "CoreSimulator", "Caches"])
    }

    static let expectedLabels = [
        "Xcode — DerivedData",
        "Xcode — Archives",
        "Xcode — iOS DeviceSupport",
        "Xcode — CoreSimulator Caches",
    ]

    @discardableResult
    private func makeRoot(_ url: URL, files: [(String, Int)] = [("build.bin", 4_096)]) throws -> URL {
        try FixtureBuilder.makeTree(in: url, files)
    }

    private func scan(
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void = { _, _ in }
    ) async throws -> ScannerOutcome {
        try await scanner.scan(
            in: environment,
            options: ScanOptions(includeDeveloperData: true),
            onProgress: onProgress
        )
    }

    private func producedItems(_ outcome: ScannerOutcome) -> [CleanupItem] {
        guard case .produced(let items) = outcome else {
            XCTFail("expected .produced, got \(outcome)")
            return []
        }
        return items
    }

    // MARK: - Discovery + classification

    func testProducesOneItemPerPresentXcodeRoot() async throws {
        try makeRoot(derivedData)
        try makeRoot(archives, files: [("MyApp 1.0.xcarchive/Info.plist", 2_048)])
        try makeRoot(deviceSupport, files: [("16.4 (20F71)/symbols", 8_192)])
        try makeRoot(simulatorCaches, files: [("com.apple.CoreSimulator/cache.db", 1_024)])

        let items = producedItems(try await scan())

        XCTAssertEqual(
            items.map { canonicalTestPath($0.path).path },
            [derivedData, archives, deviceSupport, simulatorCaches]
                .map { canonicalTestPath($0).path },
            "one item per root, in row order"
        )

        let byLabel = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        XCTAssertEqual(byLabel["Xcode — DerivedData"]?.riskLevel, .safe)
        XCTAssertEqual(byLabel["Xcode — DerivedData"]?.deletionMethod, .trashDirectory)
        XCTAssertEqual(byLabel["Xcode — DerivedData"]?.selected, true, ".safe rows preselect")

        XCTAssertEqual(byLabel["Xcode — Archives"]?.riskLevel, .review)
        XCTAssertEqual(byLabel["Xcode — Archives"]?.deletionMethod, .trashDirectory)
        XCTAssertEqual(byLabel["Xcode — Archives"]?.selected, false, ".review rows never preselect")

        XCTAssertEqual(byLabel["Xcode — iOS DeviceSupport"]?.riskLevel, .review)
        XCTAssertEqual(byLabel["Xcode — iOS DeviceSupport"]?.deletionMethod, .trashDirectory)

        XCTAssertEqual(byLabel["Xcode — CoreSimulator Caches"]?.riskLevel, .safe)
        XCTAssertEqual(byLabel["Xcode — CoreSimulator Caches"]?.deletionMethod, .removeContents)

        for item in items {
            XCTAssertEqual(item.category, .developerData)
            XCTAssertEqual(item.appName, "Xcode")
            XCTAssertEqual(item.fileCount, 1)
            XCTAssertGreaterThan(item.size, 0)
            XCTAssertFalse(item.reason.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    func testEmptyRootsProduceNoItems() async throws {
        try makeRoot(derivedData, files: [])

        let items = producedItems(try await scan())

        XCTAssertTrue(items.isEmpty, "an empty root has nothing to clean")
    }

    // MARK: - Per-row skips

    func testAbsentRootsAreSkippedPerRowWithoutFailingTheScanner() async throws {
        let recorder = StateRecorder()
        let outcome = try await scan { key, state in
            recorder.record(key, state) // one write per row: no aggregate key emitted
        }
        let states = recorder.states

        XCTAssertEqual(producedItems(outcome), [])
        XCTAssertEqual(states.count, 4, "every absent root gets its own skipped row")
        for label in Self.expectedLabels {
            guard case .skipped(.pathNotFound(let path))? = states[ScannerKey(id: .developerData, label: label)]
            else {
                XCTFail("expected .skipped(.pathNotFound) row for \(label), got \(states)")
                continue
            }
            XCTAssertFalse(path.isEmpty)
        }
    }

    func testMixedPresenceSkipsOnlyAbsentRows() async throws {
        try makeRoot(derivedData)

        let recorder = StateRecorder()
        let items = producedItems(try await scan { key, state in
            recorder.record(key, state)
        })
        let states = recorder.states

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(canonicalTestPath(items[0].path).path, canonicalTestPath(derivedData).path)

        let skipped = states.filter {
            if case .skipped = $0.value { return true }
            return false
        }
        XCTAssertEqual(
            Set(skipped.keys.map(\.label)),
            ["Xcode — Archives", "Xcode — iOS DeviceSupport", "Xcode — CoreSimulator Caches"]
        )
    }

    // MARK: - Fan-out contract

    func testRowKeysExposeExactlyTheFourRoots() {
        let keys = scanner.rowKeys(environment: environment, options: ScanOptions(includeDeveloperData: true))
        XCTAssertEqual(keys.map(\.label), Self.expectedLabels)
        XCTAssertEqual(Set(keys.map(\.id)), [.developerData])
    }

    func testAggregateProgressKeyIsNeverEmittedByTheScannerItself() async throws {
        try makeRoot(derivedData)

        let recorder = StateRecorder()
        _ = producedItems(try await scan { key, state in
            recorder.record(key, state)
        })

        let aggregate = scanner.progressKey
        XCTAssertFalse(
            recorder.states.keys.contains(aggregate),
            "the aggregate key is coordinator bookkeeping; fan-out scanners emit only row keys"
        )
    }

    func testCompletedRowsCarryPerRowTotals() async throws {
        try makeRoot(derivedData, files: [("a.bin", 4_096), ("b.bin", 4_096)])
        try makeRoot(archives)

        let recorder = StateRecorder()
        _ = producedItems(try await scan { key, state in
            if case .completed = state { recorder.record(key, state) }
        })
        let states = recorder.states

        guard case .completed(_, let itemCount)? = states[ScannerKey(id: .developerData, label: "Xcode — DerivedData")]
        else {
            return XCTFail("DerivedData row never completed: \(states)")
        }
        XCTAssertEqual(itemCount, 2)
        XCTAssertNotNil(states[ScannerKey(id: .developerData, label: "Xcode — Archives")])
    }
}
