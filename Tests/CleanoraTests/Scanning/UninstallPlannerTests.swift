import XCTest
@testable import Cleanora

/// M-06 — the uninstall plan: the app bundle plus every related file found
/// by bundle ID, all `.review` + `.moveToTrash`, missing locations skipped.
final class UninstallPlannerTests: TempHomeTestCase {
    private let appName = "Foo"
    private let bundleID = "com.example.foo"

    private var app: InstalledApp!
    private var support: URL { environment.applicationSupport }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let bundleURL = try FixtureBuilder.makeTree(
            in: environment.userApplications.appendingPathComponent("Foo.app"),
            [("Contents/MacOS/Foo", 4_096)]
        )
        app = InstalledApp(
            name: appName,
            bundleID: bundleID,
            url: bundleURL,
            bundleSize: 4_096,
            version: "1.2.3"
        )
    }

    private func makeDir(_ relative: [String]) throws -> URL {
        try FixtureBuilder.makeTree(
            in: tempHome.appending(relative),
            [("data.bin", 1_024)]
        )
    }

    private func makeFile(_ relative: [String], size: Int = 512) throws -> URL {
        let url = tempHome.appending(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: size).write(to: url)
        return url
    }

    private func plannedPaths(_ items: [CleanupItem]) -> [String] {
        items.map { PathNormalizer.canonicalized($0.path).path }
    }

    // MARK: - Full plan

    func testPlanIncludesBundleAndEveryRelatedLocation() throws {
        let caches = try makeDir(["Library", "Caches", bundleID])
        let preferences = try makeFile(["Library", "Preferences", "\(bundleID).plist"])
        let appSupportByName = try makeDir(["Library", "Application Support", appName])
        let appSupportByBundle = try makeDir(["Library", "Application Support", bundleID])
        let containers = try makeDir(["Library", "Containers", bundleID])
        let savedState = try makeDir(["Library", "Saved Application State", "\(bundleID).savedState"])
        let httpStorageDir = try makeDir(["Library", "HTTPStorages", bundleID])
        let httpStorageCookies = try makeFile(["Library", "HTTPStorages", "\(bundleID).binarycookies"])
        let webkit = try makeDir(["Library", "WebKit", bundleID])

        let items = UninstallPlanner.plan(for: app, environment: environment)

        XCTAssertEqual(items.count, 10, "bundle + every existing related location")
        let paths = plannedPaths(items)
        for expected in [caches, preferences, appSupportByName, appSupportByBundle,
                         containers, savedState, httpStorageDir, httpStorageCookies, webkit] {
            XCTAssertTrue(paths.contains(PathNormalizer.canonicalized(expected).path),
                          "missing: \(expected.path)")
        }

        // The flow contract: review-only, recoverable, nothing preselected.
        for item in items {
            XCTAssertEqual(item.category, .appLeftovers, item.name)
            XCTAssertEqual(item.riskLevel, .review, item.name)
            XCTAssertEqual(item.deletionMethod, .moveToTrash, item.name)
            XCTAssertEqual(item.confirmationLevel, .standard, item.name)
            XCTAssertEqual(item.appName, appName, item.name)
            XCTAssertEqual(item.selected, false, "\(item.name) must never preselect")
            XCTAssertFalse(item.reason.isEmpty, item.name)
        }

        XCTAssertEqual(items.first?.path, app.url, "the bundle itself leads the plan")
        XCTAssertEqual(items.first?.size, 4_096, "bundle size comes from the inventory")
    }

    func testPlanSkipsMissingRelatedFiles() throws {
        let caches = try makeDir(["Library", "Caches", bundleID])

        let items = UninstallPlanner.plan(for: app, environment: environment)

        XCTAssertEqual(items.count, 2, "absent locations produce no items")
        XCTAssertEqual(plannedPaths(items), [
            PathNormalizer.canonicalized(app.url).path,
            PathNormalizer.canonicalized(caches).path,
        ])
    }

    func testApplicationSupportMatchesNameOrBundleID() throws {
        let byName = try makeDir(["Library", "Application Support", appName])

        XCTAssertEqual(
            plannedPaths(UninstallPlanner.plan(for: app, environment: environment)),
            [
                PathNormalizer.canonicalized(app.url).path,
                PathNormalizer.canonicalized(byName).path,
            ]
        )

        let byBundle = try makeDir(["Library", "Application Support", bundleID])
        XCTAssertEqual(
            Set(plannedPaths(UninstallPlanner.plan(for: app, environment: environment)).dropFirst()),
            [
                PathNormalizer.canonicalized(byName).path,
                PathNormalizer.canonicalized(byBundle).path,
            ].asSet,
            "both spellings are found when both exist"
        )
    }

    func testSavedApplicationStateAndHTTPStoragesMatchByBundlePrefix() throws {
        let savedState = try makeDir(["Library", "Saved Application State", "\(bundleID).savedState"])
        try makeDir(["Library", "Saved Application State", "com.other.savedState"])
        let httpStorages = try makeDir(["Library", "HTTPStorages", bundleID])
        try makeDir(["Library", "HTTPStorages", "com.examplefoobar"])

        let items = UninstallPlanner.plan(for: app, environment: environment)

        XCTAssertEqual(items.count, 3, "bundle + saved state + http storages; lookalikes excluded")
        let paths = Set(plannedPaths(items))
        XCTAssertTrue(paths.contains(PathNormalizer.canonicalized(savedState).path))
        XCTAssertTrue(paths.contains(PathNormalizer.canonicalized(httpStorages).path))
    }

    func testBundlelessAppPlansOnlyBundleAndNameMatchedSupport() throws {
        let bundleless = InstalledApp(
            name: "Widget",
            bundleID: nil,
            url: app.url,
            bundleSize: 4_096,
            version: nil
        )
        let appSupport = try makeDir(["Library", "Application Support", "Widget"])
        try makeDir(["Library", "Caches", "com.stray.bundle"])

        let items = UninstallPlanner.plan(for: bundleless, environment: environment)

        XCTAssertEqual(plannedPaths(items), [
            PathNormalizer.canonicalized(bundleless.url).path,
            PathNormalizer.canonicalized(appSupport).path,
        ])
    }

    func testPlannedSizesReflectFixtureContents() throws {
        try makeDir(["Library", "Caches", bundleID])

        let items = UninstallPlanner.plan(for: app, environment: environment)
        let caches = items.first { $0.path.lastPathComponent == bundleID }

        XCTAssertGreaterThanOrEqual(try XCTUnwrap(caches).size, 1_024)
    }
}

private extension Array where Element == String {
    var asSet: Set<String> { Set(self) }
}
