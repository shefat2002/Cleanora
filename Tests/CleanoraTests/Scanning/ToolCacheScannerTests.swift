import XCTest
@testable import Cleanora

/// P-02..P-05 — the per-tool package-manager cache scanners (Homebrew, npm,
/// pip, Yarn). Same contract for every tool: `.safe` `.removeContents` items
/// for each present cache root; when no root of a tool exists at all the
/// whole scanner reports `.skipped(.toolNotInstalled)`.
final class ToolCacheScannerTests: TempHomeTestCase {
    private let noProgress: @Sendable (ScannerKey, ScannerState) -> Void = { _, _ in }

    // MARK: - Fixture roots

    private var homebrewCache: URL {
        environment.home.appending(["Library", "Caches", "Homebrew"])
    }
    private var npmCacache: URL { environment.home.appending([".npm", "_cacache"]) }
    private var npmLogs: URL { environment.home.appending([".npm", "_logs"]) }
    private var pipCache: URL { environment.home.appending(["Library", "Caches", "pip"]) }
    private var pipXDGCache: URL { environment.home.appending([".cache", "pip"]) }
    private var yarnCache: URL { environment.home.appending(["Library", "Caches", "Yarn"]) }
    private var yarnBerryCache: URL { environment.home.appending([".yarn", "berry", "cache"]) }

    private func scan(
        _ scanner: any Cleanora.Scanner,
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void = { _, _ in }
    ) async throws -> ScannerOutcome {
        try await scanner.scan(
            in: environment,
            options: ScanOptions(includeDeveloperData: true),
            onProgress: onProgress
        )
    }

    private func producedItems(_ outcome: ScannerOutcome, file: StaticString = #filePath, line: UInt = #line)
        -> [CleanupItem] {
        guard case .produced(let items) = outcome else {
            XCTFail("expected .produced, got \(outcome)", file: file, line: line)
            return []
        }
        return items
    }

    // MARK: - P-02 Homebrew

    func testHomebrewCacheProducesOneSafeRemoveContentsItem() async throws {
        try FixtureBuilder.makeTree(in: homebrewCache, [("downloads/foo--1.2.3.bottle.tar.gz", 8_192)])

        let items = producedItems(try await scan(HomebrewScanner()))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(canonicalTestPath(items[0].path).path, canonicalTestPath(homebrewCache).path)
        XCTAssertEqual(items[0].riskLevel, .safe)
        XCTAssertEqual(items[0].deletionMethod, .removeContents)
        XCTAssertEqual(items[0].appName, "Homebrew")
        XCTAssertEqual(items[0].category, .developerData)
        XCTAssertEqual(items[0].selected, true)
        XCTAssertGreaterThan(items[0].size, 0, "the downloads subtree is part of the cache")
        XCTAssertFalse(items[0].reason.isEmpty)
    }

    func testHomebrewAbsentIsSkippedAsToolNotInstalled() async throws {
        let outcome = try await scan(HomebrewScanner())
        XCTAssertEqual(outcome, .skipped(.toolNotInstalled("Homebrew")))
    }

    func testHomebrewUnreadableCacheIsSkippedWithPermissionDenied() async throws {
        try XCTSkipUnless(getuid() != 0, "chmod-based unreadability does not apply to root")
        try FixtureBuilder.makeTree(in: homebrewCache, [("x", 16)])
        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: homebrewCache.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: homebrewCache.path)
        }

        let outcome = try await scan(HomebrewScanner())
        XCTAssertEqual(outcome, .skipped(.permissionDenied(homebrewCache.path)))
    }

    // MARK: - P-03 npm

    func testNpmReportsCacacheAndLogsAsSeparateItems() async throws {
        try FixtureBuilder.makeTree(in: npmCacache, [("content-v2/sha512/aa", 4_096)])
        try FixtureBuilder.makeTree(in: npmLogs, [("2026-09-12T10-00-00-debug-0.log", 512)])

        let items = producedItems(try await scan(NpmScanner()))

        XCTAssertEqual(
            items.map { canonicalTestPath($0.path).path },
            [npmCacache, npmLogs].map { canonicalTestPath($0).path }
        )
        for item in items {
            XCTAssertEqual(item.riskLevel, .safe)
            XCTAssertEqual(item.deletionMethod, .removeContents)
            XCTAssertEqual(item.appName, "npm")
        }
    }

    func testNpmWithOnlyLogsStillReportsThePresentRoot() async throws {
        try FixtureBuilder.makeTree(in: npmLogs, [("debug.log", 128)])

        let items = producedItems(try await scan(NpmScanner()))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(canonicalTestPath(items[0].path).path, canonicalTestPath(npmLogs).path)
    }

    func testNpmAbsentIsSkippedAsToolNotInstalled() async throws {
        let outcome = try await scan(NpmScanner())
        XCTAssertEqual(outcome, .skipped(.toolNotInstalled("npm")))
    }

    // MARK: - P-04 pip

    func testPipReportsBothCacheLocations() async throws {
        try FixtureBuilder.makeTree(in: pipCache, [("http-v2/ab/cd", 4_096)])
        try FixtureBuilder.makeTree(in: pipXDGCache, [("selfcheck", 64)])

        let items = producedItems(try await scan(PipScanner()))

        XCTAssertEqual(
            Set(items.map { canonicalTestPath($0.path).path }),
            Set([pipCache, pipXDGCache].map { canonicalTestPath($0).path })
        )
        for item in items {
            XCTAssertEqual(item.riskLevel, .safe)
            XCTAssertEqual(item.deletionMethod, .removeContents)
            XCTAssertEqual(item.appName, "pip")
        }
    }

    func testPipAbsentIsSkippedAsToolNotInstalled() async throws {
        let outcome = try await scan(PipScanner())
        XCTAssertEqual(outcome, .skipped(.toolNotInstalled("pip")))
    }

    // MARK: - P-05 Yarn

    func testYarnReportsBothCacheLocations() async throws {
        try FixtureBuilder.makeTree(in: yarnCache, [("npm/lodash-4.17.21.tgz", 4_096)])
        try FixtureBuilder.makeTree(in: yarnBerryCache, [("lodash-npm-4.17.21.zip", 4_096)])

        let items = producedItems(try await scan(YarnScanner()))

        XCTAssertEqual(
            Set(items.map { canonicalTestPath($0.path).path }),
            Set([yarnCache, yarnBerryCache].map { canonicalTestPath($0).path })
        )
        for item in items {
            XCTAssertEqual(item.riskLevel, .safe)
            XCTAssertEqual(item.deletionMethod, .removeContents)
            XCTAssertEqual(item.appName, "Yarn")
        }
    }

    func testYarnAbsentIsSkippedAsToolNotInstalled() async throws {
        let outcome = try await scan(YarnScanner())
        XCTAssertEqual(outcome, .skipped(.toolNotInstalled("Yarn")))
    }

    // MARK: - Shared row behavior

    func testEmptyRootsCompleteWithZeroTotalsAndNoItems() async throws {
        try FixtureBuilder.makeTree(in: npmCacache, [])
        try FixtureBuilder.makeTree(in: npmLogs, [])

        let recorder = StateRecorder()
        let items = producedItems(try await scan(NpmScanner()) { key, state in
            if case .completed = state { recorder.record(key, state) }
        })
        let states = recorder.states

        XCTAssertTrue(items.isEmpty)
        guard case .completed(0, 0)? = states[ScannerKey(id: .developerData, label: "npm")] else {
            return XCTFail("expected a zero-total completed row, got \(states)")
        }
    }

    func testToolScannersCarveOutSingleDeveloperRows() {
        XCTAssertEqual(HomebrewScanner().progressKey, ScannerKey(id: .developerData, label: "Homebrew"))
        XCTAssertEqual(NpmScanner().progressKey, ScannerKey(id: .developerData, label: "npm"))
        XCTAssertEqual(PipScanner().progressKey, ScannerKey(id: .developerData, label: "pip"))
        XCTAssertEqual(YarnScanner().progressKey, ScannerKey(id: .developerData, label: "Yarn"))
        XCTAssertEqual(DockerScanner().progressKey, ScannerKey(id: .developerData, label: "Docker"))
        XCTAssertEqual(XcodeScanner().progressKey, ScannerKey(id: .developerData, label: "Xcode"))
        for scanner: any Cleanora.Scanner in [
            HomebrewScanner(), NpmScanner(), PipScanner(), YarnScanner(), DockerScanner(),
        ] {
            XCTAssertFalse(scanner.isPhaseOne, "developer scanners are Phase 2")
            XCTAssertEqual(scanner.category, .developerData)
        }
    }
}
