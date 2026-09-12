import XCTest
@testable import Cleanora

/// P-07 — DeveloperScanner composite: fans the six per-tool scanners out
/// concurrently behind one Scanner, gated by `options.includeDeveloperData`,
/// with per-tool progress rows; plus the `fullScanners` factory and the
/// coordinator's fan-out key expansion.
final class DeveloperScannerTests: TempHomeTestCase {
    private let noProgress: @Sendable (ScannerKey, ScannerState) -> Void = { _, _ in }

    private var derivedData: URL {
        environment.home.appending(["Library", "Developer", "Xcode", "DerivedData"])
    }
    private var homebrewCache: URL {
        environment.home.appending(["Library", "Caches", "Homebrew"])
    }
    private var npmCacache: URL { environment.home.appending([".npm", "_cacache"]) }

    /// Deterministic fixture set: Xcode + Homebrew + npm present, Docker
    /// force-absent regardless of what the host machine has installed.
    private func makeScanner() -> DeveloperScanner {
        DeveloperScanner(subScanners: [
            XcodeScanner(),
            HomebrewScanner(),
            NpmScanner(),
            DockerScanner(cliDetector: { false }),
        ])
    }

    private func producedItems(_ outcome: ScannerOutcome, file: StaticString = #filePath, line: UInt = #line)
        -> [CleanupItem] {
        guard case .produced(let items) = outcome else {
            XCTFail("expected .produced, got \(outcome)", file: file, line: line)
            return []
        }
        return items
    }

    // MARK: - Gating

    func testDisabledByUserWhenDeveloperDataOff() async throws {
        let recorder = StateRecorder()
        let outcome = try await makeScanner().scan(
            in: environment,
            options: ScanOptions(includeDeveloperData: false),
            onProgress: { key, state in recorder.record(key, state) }
        )

        XCTAssertEqual(outcome, .skipped(.disabledByUser))
        XCTAssertTrue(recorder.states.isEmpty, "a gated-off composite emits no rows at all")
    }

    // MARK: - Fan-out

    func testFansToolsOutIntoOneOutcomeWithPerToolRows() async throws {
        try FixtureBuilder.makeTree(in: derivedData, [("ModuleCache/foo.o", 4_096)])
        try FixtureBuilder.makeTree(in: homebrewCache, [("downloads/x.bottle.tar.gz", 2_048)])
        try FixtureBuilder.makeTree(in: npmCacache, [("content-v2/aa", 1_024)])

        let recorder = StateRecorder()
        let outcome = try await makeScanner().scan(
            in: environment,
            options: ScanOptions(includeDeveloperData: true),
            onProgress: { key, state in recorder.record(key, state) }
        )
        let states = recorder.states

        let items = producedItems(outcome)
        XCTAssertEqual(items.count, 3, "Xcode root + Homebrew cache + npm caches merge into one list")
        XCTAssertTrue(items.allSatisfy { $0.category == .developerData })
        XCTAssertEqual(
            Set(items.map(\.appName)),
            ["Xcode", "Homebrew", "npm"],
            "items keep their per-tool grouping for the Results screen"
        )

        for label in ["Xcode — DerivedData", "Homebrew", "npm"] {
            guard case .completed? = states[ScannerKey(id: .developerData, label: label)] else {
                return XCTFail("missing completed row for \(label): \(states)")
            }
        }
        guard case .running? = states[ScannerKey(id: .developerData, label: "Developer Data")] else {
            return XCTFail("the composite row should track aggregate progress, got \(states)")
        }
    }

    func testAllToolsAbsentProducesEmptyOutcomeWithPerRowSkips() async throws {
        let recorder = StateRecorder()
        let outcome = try await makeScanner().scan(
            in: environment,
            options: ScanOptions(includeDeveloperData: true),
            onProgress: { key, state in recorder.record(key, state) }
        )
        let states = recorder.states

        XCTAssertEqual(producedItems(outcome), [])
        XCTAssertEqual(
            states[ScannerKey(id: .developerData, label: "Homebrew")],
            .skipped(.toolNotInstalled("Homebrew"))
        )
        XCTAssertEqual(
            states[ScannerKey(id: .developerData, label: "npm")],
            .skipped(.toolNotInstalled("npm"))
        )
        XCTAssertEqual(
            states[ScannerKey(id: .developerData, label: "Docker")],
            .skipped(.toolNotInstalled("Docker"))
        )
        guard case .skipped(.pathNotFound)? = states[ScannerKey(id: .developerData, label: "Xcode — DerivedData")]
        else {
            return XCTFail("Xcode rows skip per root, got \(states)")
        }
    }

    // MARK: - Row keys (UI surface)

    func testRowKeysExpandPerToolOnlyWhenEnabled() {
        let scanner = makeScanner()
        let off = scanner.rowKeys(
            environment: environment,
            options: ScanOptions(includeDeveloperData: false)
        )
        XCTAssertEqual(off, [ScannerKey(id: .developerData, label: "Developer Data")])

        let on = scanner.rowKeys(
            environment: environment,
            options: ScanOptions(includeDeveloperData: true)
        )
        XCTAssertEqual(
            on.count, 8,
            "composite + 4 Xcode root rows + Homebrew + npm + Docker"
        )
        XCTAssertEqual(on.first, ScannerKey(id: .developerData, label: "Developer Data"))
        XCTAssertTrue(on.contains(ScannerKey(id: .developerData, label: "Xcode — DerivedData")))
    }

    // MARK: - fullScanners factory + key expansion

    func testFullScannersExtendsPhaseOneWithDeveloperAndLargeFiles() {
        let all = ScanCoordinator.fullScanners(
            environment: environment,
            options: ScanOptions(includeDeveloperData: true)
        )

        XCTAssertEqual(all.count, 7, "5 phase-one scanners + developer composite + large files")
        XCTAssertEqual(
            Set(all.map(\.category)),
            Set(ScanCategory.phaseOne + [.developerData, .largeFiles])
        )
        XCTAssertEqual(
            ScanCoordinator.phaseOneScanners(environment: environment).count,
            5,
            "the phase-one set stays untouched"
        )
    }

    func testAllProgressKeysExpandFanOutRows() {
        func makeCoordinator(_ options: ScanOptions) -> ScanCoordinator {
            ScanCoordinator(
                scanners: ScanCoordinator.fullScanners(environment: environment, options: options),
                environment: environment,
                options: options,
                diskInfo: DiskInfoProvider()
            )
        }

        let everythingOn = ScanOptions(
            enabledCategories: Set(ScanCategory.phaseOne + [.developerData, .largeFiles]),
            includeDeveloperData: true
        )
        let keys = makeCoordinator(everythingOn).allProgressKeys()
        XCTAssertEqual(keys.count, 16, "5 phase-one + (1 composite + 4 Xcode rows + 5 tools) + 1 large files")
        XCTAssertEqual(
            keys.filter { $0.id == .developerData }.map(\.label),
            [
                "Developer Data",
                "Xcode — DerivedData", "Xcode — Archives",
                "Xcode — iOS DeviceSupport", "Xcode — CoreSimulator Caches",
                "Homebrew", "npm", "pip", "Yarn", "Docker",
            ]
        )

        let devOff = ScanOptions(
            enabledCategories: Set(ScanCategory.phaseOne + [.developerData, .largeFiles]),
            includeDeveloperData: false
        )
        XCTAssertEqual(makeCoordinator(devOff).allProgressKeys().count, 7,
                       "a gated-off composite collapses to its single row")

        let devCategoryOff = ScanOptions(
            enabledCategories: Set(ScanCategory.phaseOne + [.largeFiles]),
            includeDeveloperData: true
        )
        let keysOff = makeCoordinator(devCategoryOff).allProgressKeys()
        XCTAssertEqual(
            keysOff.filter { $0.id == .developerData },
            [ScannerKey(id: .developerData, label: "Developer Data")],
            "a disabled category renders exactly one explained row, not ten"
        )
        XCTAssertEqual(keysOff.count, 7)
    }

    // MARK: - Coordinator integration

    func testCoordinatorRunSurfacesDeveloperItems() async throws {
        try FixtureBuilder.makeTree(in: derivedData, [("Index/store", 4_096)])
        let options = ScanOptions(
            enabledCategories: Set(ScanCategory.phaseOne + [.developerData, .largeFiles]),
            includeDeveloperData: true
        )
        let coordinator = ScanCoordinator(
            scanners: ScanCoordinator.fullScanners(environment: environment, options: options),
            environment: environment,
            options: options,
            diskInfo: DiskInfoProvider()
        )

        var updates: [ScanUpdate] = []
        for await update in coordinator.run() {
            updates.append(update)
            if case .finished = update { break }
        }

        guard case .finished(let result)? = updates.last else {
            return XCTFail("expected a finished result, got \(updates.last.map(String.init(describing:)) ?? "nil")")
        }
        XCTAssertTrue(
            result.items.contains { canonicalTestPath($0.path).path == canonicalTestPath(derivedData).path },
            "the DerivedData item survives dedup and lands in the final result"
        )
        XCTAssertTrue(result.scannerKeys.contains(ScannerKey(id: .developerData, label: "Developer Data")))
    }
}
