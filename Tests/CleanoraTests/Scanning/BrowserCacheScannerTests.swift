import XCTest
@testable import Cleanora

/// C-03 — BrowserCacheScanner + BrowserCatalog.
final class BrowserCacheScannerTests: TempHomeTestCase {
    private let scanner = BrowserCacheScanner()
    private let fileManager = FileManager.default
    private let noProgress: @Sendable (ScannerKey, ScannerState) -> Void = { _, _ in }

    /// Creates `<profileRoot>/<profile>/<subdir>` with one file each.
    private func makeProfile(
        _ baseComponents: [String],
        profile: String,
        caches: Set<String>,
        extras: [String] = []
    ) throws -> URL {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        var url = environment.caches
        for component in baseComponents {
            url = url.appendingPathComponent(component, isDirectory: true)
        }
        url = url.appendingPathComponent(profile, isDirectory: true)
        for sub in caches {
            try FixtureBuilder.makeTree(in: url.appendingPathComponent(sub), [("blob.bin", 2_048)])
        }
        for extra in extras {
            try FixtureBuilder.makeTree(in: url.appendingPathComponent(extra), [("keep.bin", 10)])
        }
        return url
    }

    private func scan() async throws -> ScannerOutcome {
        try await scanner.scan(in: environment, options: ScanOptions(), onProgress: noProgress)
    }

    private func producedItems(_ outcome: ScannerOutcome) throws -> [CleanupItem] {
        guard case .produced(let items) = outcome else {
            XCTFail("expected .produced, got \(outcome)")
            return []
        }
        return items
    }

    // MARK: - Chromium layout

    func testChromeProfileCacheSubdirectoriesAreReported() async throws {
        let profile = try makeProfile(
            ["Google", "Chrome"],
            profile: "Default",
            caches: Set(BrowserCatalog.chromiumCacheDirectories),
            extras: ["Preferences", "Local Storage"]
        )

        let items = try producedItems(try await scan())

        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(Set(items.map(\.appName)), ["Chrome"])
        for item in items {
            XCTAssertEqual(item.category, .browserCaches)
            XCTAssertEqual(item.riskLevel, .safe)
            XCTAssertEqual(item.deletionMethod, .removeContents)
            XCTAssertEqual(
                canonicalTestPath(item.path.deletingLastPathComponent()).path,
                canonicalTestPath(profile).path
            )
            XCTAssertTrue(BrowserCatalog.chromiumCacheDirectories.contains(item.path.lastPathComponent))
            XCTAssertFalse(item.reason.isEmpty)
            XCTAssertGreaterThan(item.size, 0)
        }
        // The profile directory itself is never an item — it must survive.
        XCTAssertFalse(items.contains { $0.path.lastPathComponent == "Default" })
    }

    func testOnlyExistingCacheSubdirectoriesAreReported() async throws {
        try makeProfile(["Google", "Chrome"], profile: "Profile 1", caches: ["Cache"])

        let items = try producedItems(try await scan())

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.path.lastPathComponent, "Cache")
    }

    func testNonDirectoryProfileEntriesAreIgnored() async throws {
        try makeProfile(["Google", "Chrome"], profile: "Default", caches: ["Cache"])
        // A stray file where a profile would be.
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        try Data("x".utf8).write(
            to: environment.caches
                .appendingPathComponent("Google")
                .appendingPathComponent("Chrome")
                .appendingPathComponent("not-a-profile")
        )

        let items = try producedItems(try await scan())

        XCTAssertEqual(items.count, 1)
    }

    // MARK: - Other Chromium variants + Firefox

    func testChromiumVariantsAreScannedAtTheirOwnBases() async throws {
        try makeProfile(["Microsoft Edge"], profile: "Default", caches: ["Cache"])
        try makeProfile(["BraveSoftware", "Brave-Browser"], profile: "Default", caches: ["GPUCache"])
        try makeProfile(["Arc"], profile: "Default", caches: ["Code Cache"])
        try makeProfile(["com.operasoftware.Opera"], profile: "Default", caches: ["Service Worker"])

        let items = try producedItems(try await scan())

        XCTAssertEqual(Set(items.map(\.appName)), ["Edge", "Brave", "Arc", "Opera"])
        XCTAssertEqual(items.count, 4)
        let opera = try XCTUnwrap(items.first { $0.appName == "Opera" })
        XCTAssertEqual(
            canonicalTestPath(opera.path).path,
            canonicalTestPath(
                environment.caches
                    .appendingPathComponent("com.operasoftware.Opera")
                    .appendingPathComponent("Default")
                    .appendingPathComponent("Service Worker")
            ).path
        )
    }

    func testFirefoxProfileCachesAreReported() async throws {
        let profileRoot = try makeProfile(
            ["Firefox", "Profiles"],
            profile: "abcd1234.default-release",
            caches: Set(BrowserCatalog.firefoxCacheDirectories)
        )

        let items = try producedItems(try await scan())

        XCTAssertEqual(items.count, BrowserCatalog.firefoxCacheDirectories.count)
        XCTAssertEqual(Set(items.map(\.appName)), ["Firefox"])
        for item in items {
            XCTAssertEqual(item.deletionMethod, .removeContents)
            XCTAssertEqual(
                canonicalTestPath(item.path.deletingLastPathComponent()).path,
                canonicalTestPath(profileRoot).path
            )
            XCTAssertTrue(BrowserCatalog.firefoxCacheDirectories.contains(item.path.lastPathComponent))
        }
    }

    // MARK: - Safari

    func testSafariIsReportedForReviewWithTrashDirectory() async throws {
        try makeProfile(["com.apple.Safari"], profile: "fsCachedData", caches: ["data"])

        let items = try producedItems(try await scan())

        // Safari is a single whole-directory item, never preselected.
        let safari = items.filter { $0.appName == "Safari" }
        XCTAssertEqual(safari.count, 1)
        XCTAssertEqual(safari.first?.riskLevel, .review)
        XCTAssertEqual(safari.first?.selected, false)
        XCTAssertEqual(safari.first?.deletionMethod, .trashDirectory)
        XCTAssertEqual(
            safari.first?.path.path,
            environment.caches.appendingPathComponent("com.apple.Safari").path
        )
    }

    func testSafariTCCDenialIsSkippedAsPermissionDenied() async throws {
        try XCTSkipUnless(getuid() != 0, "chmod-based unreadability does not apply to root")
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        let safari = environment.caches.appendingPathComponent("com.apple.Safari")
        try FixtureBuilder.makeTree(in: safari, [("Cache.db", 1_024)])
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: safari.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safari.path) }

        let outcome = try await scan()

        XCTAssertEqual(outcome, .skipped(.permissionDenied(safari.path)))
    }

    // MARK: - Nothing installed

    func testNoBrowserInstallProducesEmptyOutcome() async throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)

        let outcome = try await scan()

        XCTAssertEqual(outcome, .produced([]))
    }

    func testMissingCachesRootIsSkippedWithPathNotFound() async throws {
        let outcome = try await scan()

        XCTAssertEqual(outcome, .skipped(.pathNotFound(environment.caches.path)))
    }

    // MARK: - Catalog integrity

    func testCatalogCoversEverySpecBrowser() {
        XCTAssertEqual(
            Set(BrowserCatalog.all.map(\.name)),
            ["Chrome", "Edge", "Brave", "Arc", "Opera", "Firefox", "Safari"]
        )
        XCTAssertEqual(BrowserCatalog.chromiumCacheDirectories, ["Cache", "Code Cache", "GPUCache", "Service Worker"])
        XCTAssertEqual(BrowserCatalog.firefoxCacheDirectories, ["cache2", "startupCache", "shader-cache"])
        for browser in BrowserCatalog.all {
            XCTAssertFalse(browser.reason.isEmpty)
        }
    }
}
