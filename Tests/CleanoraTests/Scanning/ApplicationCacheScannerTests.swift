import XCTest
@testable import Cleanora

/// C-02 — ApplicationCacheScanner + AppCacheOverrides.
final class ApplicationCacheScannerTests: TempHomeTestCase {
    private let scanner = ApplicationCacheScanner()
    private let fileManager = FileManager.default
    private let noProgress: @Sendable (ScannerKey, ScannerState) -> Void = { _, _ in }

    @discardableResult
    private func makeCacheDir(_ name: String, files: [(String, Int)]) throws -> URL {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        return try FixtureBuilder.makeTree(
            in: environment.caches.appendingPathComponent(name, isDirectory: true),
            files
        )
    }

    private func scanOutcome(_ scanner: Cleanora.Scanner = ApplicationCacheScanner()) async throws
        -> ScannerOutcome {
        try await scanner.scan(in: environment, options: ScanOptions(), onProgress: noProgress)
    }

    // MARK: - Discovery

    func testProducesItemsForReverseDNSAndLegacyCacheDirectories() async throws {
        let chrome = try makeCacheDir("com.google.Chrome", files: [("data/cache.bin", 4_096)])
        let pip = try makeCacheDir("pip", files: [("wheel.whl", 2_048)])
        // Noise that must never become an item:
        try Data("x".utf8).write(to: environment.caches.appendingPathComponent("loose-file.txt"))
        try makeCacheDir(".hidden-dir", files: [("f", 10)])
        try makeCacheDir("empty-dir", files: [])

        let outcome = try await scanOutcome()

        guard case .produced(let items) = outcome else {
            return XCTFail("expected .produced, got \(outcome)")
        }
        XCTAssertEqual(
            items.map { canonicalTestPath($0.path).path },
            [chrome, pip].map { canonicalTestPath($0).path },
            "reverse-DNS and legacy dirs are reported sorted by name; files, hidden and empty dirs are not"
        )
        XCTAssertEqual(items[0].appName, "Chrome")
        XCTAssertEqual(items[0].riskLevel, .safe)
        XCTAssertEqual(items[0].deletionMethod, .trashDirectory)
        XCTAssertEqual(items[0].fileCount, 1)
        XCTAssertGreaterThan(items[0].size, 0)
        XCTAssertEqual(items[1].appName, "Pip")
    }

    func testCleanoraOwnCacheIsNeverReported() async throws {
        try makeCacheDir("com.cleanora.app", files: [("cache.bin", 4_096)])
        try makeCacheDir("com.cleanora.helper", files: [("cache.bin", 4_096)])

        let outcome = try await scanOutcome()

        guard case .produced(let items) = outcome else {
            return XCTFail("expected .produced, got \(outcome)")
        }
        XCTAssertTrue(items.isEmpty, "own bundle data must never be a target: \(items.map(\.path.path))")
    }

    func testEveryItemHasNonEmptyReasonAndFriendlyAppName() async throws {
        try makeCacheDir("com.apple.dt.Xcode", files: [("index", 1_024)])
        try makeCacheDir("Google", files: [("foo", 1_024)])
        try makeCacheDir("io.github.some-tool", files: [("foo", 1_024)])

        let outcome = try await scanOutcome()

        guard case .produced(let items) = outcome else {
            return XCTFail("expected .produced, got \(outcome)")
        }
        XCTAssertEqual(items.count, 3)
        for item in items {
            XCTAssertFalse(item.reason.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertNotNil(item.appName)
            XCTAssertFalse(item.appName?.isEmpty ?? true)
        }
        XCTAssertEqual(Set(items.map(\.appName)), ["Xcode", "Google", "Some Tool"])
    }

    // MARK: - Overrides

    func testSafariAndDockerOverridesAreReviewAndNeverPreselected() async throws {
        try makeCacheDir("com.apple.Safari", files: [("Cache.db", 4_096)])
        try makeCacheDir("com.docker.docker", files: [("data/build.json", 4_096)])
        try makeCacheDir("com.example.plain", files: [("cache.bin", 4_096)])

        let outcome = try await scanOutcome()

        guard case .produced(let items) = outcome else {
            return XCTFail("expected .produced, got \(outcome)")
        }
        let byApp = Dictionary(uniqueKeysWithValues: items.map { ($0.appName ?? "", $0) })
        XCTAssertEqual(byApp["Safari"]?.riskLevel, .review)
        XCTAssertEqual(byApp["Safari"]?.selected, false)
        XCTAssertEqual(byApp["Docker"]?.riskLevel, .review)
        XCTAssertEqual(byApp["Docker"]?.selected, false)
        XCTAssertEqual(byApp["Plain"]?.riskLevel, .safe, "bundles without overrides stay .safe")
    }

    func testOverridesCatalogOnlyContainsReviewRisks() {
        for entry in AppCacheOverrides.standard {
            XCTAssertEqual(entry.riskLevel, .review)
            XCTAssertFalse(entry.reason.isEmpty)
        }
        XCTAssertEqual(
            Set(AppCacheOverrides.standard.map(\.bundleID)),
            ["com.apple.Safari", "com.docker.docker"]
        )
        XCTAssertNil(AppCacheOverrides.matching(bundleID: "com.unknown.app"))
        XCTAssertEqual(AppCacheOverrides.matching(bundleID: "com.apple.Safari")?.appName, "Safari")
    }

    // MARK: - Skip paths

    func testMissingCachesDirectoryIsSkippedWithPathNotFound() async throws {
        // No Library/ at all.
        let outcome = try await scanOutcome()

        XCTAssertEqual(outcome, .skipped(.pathNotFound(environment.caches.path)))
    }

    func testUnreadableCachesDirectoryIsSkippedWithPermissionDenied() async throws {
        try XCTSkipUnless(getuid() != 0, "chmod-based unreadability does not apply to root")
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        try fileManager.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: environment.caches.path
        )
        defer {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: environment.caches.path
            )
        }

        let outcome = try await scanOutcome()

        XCTAssertEqual(outcome, .skipped(.permissionDenied(environment.caches.path)))
    }

    // MARK: - Classification

    func testBundleIdentifierDetection() {
        XCTAssertEqual(ApplicationCacheScanner.bundleIdentifier(forDirectoryNamed: "com.google.Chrome"), "com.google.Chrome")
        XCTAssertEqual(ApplicationCacheScanner.bundleIdentifier(forDirectoryNamed: "org.mozilla.firefox"), "org.mozilla.firefox")
        XCTAssertEqual(ApplicationCacheScanner.bundleIdentifier(forDirectoryNamed: "net.whatsapp.WhatsApp"), "net.whatsapp.WhatsApp")
        XCTAssertEqual(ApplicationCacheScanner.bundleIdentifier(forDirectoryNamed: "io.github.tool"), "io.github.tool")
        XCTAssertNil(ApplicationCacheScanner.bundleIdentifier(forDirectoryNamed: "Google"))
        XCTAssertNil(ApplicationCacheScanner.bundleIdentifier(forDirectoryNamed: "pip"))
    }
}
