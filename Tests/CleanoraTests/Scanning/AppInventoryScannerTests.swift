import XCTest
@testable import Cleanora

/// M-06 — the applications inventory reads .app bundles from the system
/// (override-injected) and user applications folders only, and inventories
/// them read-only.
///
/// Every test MUST go through `inventory()` — it always injects the
/// applicationsOverride seam. Calling the scanner with the bare
/// `environment` would inventory the machine's real /Applications, which is
/// exactly what the seam exists to prevent.
final class AppInventoryScannerTests: TempHomeTestCase {
    private let scanner = AppInventoryScanner()

    private var systemApps: URL {
        tempRoot.appendingPathComponent("SystemApps", isDirectory: true)
    }
    private var userApps: URL {
        environment.userApplications
    }

    /// The ONLY way tests call the scanner: override always injected.
    private func inventory(environment custom: ScanEnvironment? = nil) -> [InstalledApp] {
        scanner.inventory(environment: custom ?? environmentWithSystemRoot())
    }

    private func environmentWithSystemRoot() -> ScanEnvironment {
        ScanEnvironment(
            home: tempHome,
            temporaryRoot: tempRoot,
            applicationsOverride: systemApps
        )
    }

    @discardableResult
    private func makeApp(
        _ name: String,
        bundleID: String? = "com.example.foo",
        version: String? = "1.2.3",
        in root: URL
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FixtureBuilder.makeTree(
            in: contents,
            [("MacOS/\(name)", 4_096), ("Resources/logo.png", 2_048)]
        )
        var info: [String: Any] = [:]
        if let bundleID { info["CFBundleIdentifier"] = bundleID }
        if let version { info["CFBundleShortVersionString"] = version }
        if !info.isEmpty {
            let data = try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0
            )
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        return bundleURL
    }

    // MARK: - Discovery

    func testDiscoversAppBundleInUserApplicationsFolder() throws {
        let bundle = try makeApp("Foo", in: userApps)

        let apps = inventory()

        XCTAssertEqual(apps.count, 1)
        let app = try XCTUnwrap(apps.first)
        XCTAssertEqual(app.name, "Foo")
        XCTAssertEqual(app.bundleID, "com.example.foo")
        XCTAssertEqual(app.version, "1.2.3")
        XCTAssertEqual(canonicalTestPath(app.url), canonicalTestPath(bundle))
        XCTAssertGreaterThanOrEqual(app.bundleSize, 6_144, "bundle size covers the whole tree")
    }

    func testDiscoversAppsInSystemApplicationsViaOverride() throws {
        try makeApp("Foo", in: userApps)
        try makeApp("Bar", bundleID: "com.example.bar", in: systemApps)

        let apps = inventory()

        XCTAssertEqual(apps.map(\.name), ["Bar", "Foo"], "both roots, sorted by name")
    }

    func testSortsAppsByNameAcrossRoots() throws {
        try makeApp("Zebra", in: userApps)
        try makeApp("apple", bundleID: "com.example.apple", in: userApps)

        let apps = inventory()

        XCTAssertEqual(apps.map(\.name), ["apple", "Zebra"], "case-insensitive name order")
    }

    func testOverlappingRootsAreDeduplicated() throws {
        try makeApp("Foo", in: userApps)
        // The override POINTS at the user folder — the app must appear once.
        let apps = inventory(environment: ScanEnvironment(
            home: tempHome,
            temporaryRoot: tempRoot,
            applicationsOverride: userApps
        ))

        XCTAssertEqual(apps.count, 1)
    }

    // MARK: - Filters

    func testIgnoresNonBundlesAndSymlinkedBundles() throws {
        try makeApp("Real", in: userApps)
        try FixtureBuilder.makeTree(in: userApps, [("README.txt", 128)])
        try FileManager.default.createSymbolicLink(
            at: userApps.appendingPathComponent("Alias.app"),
            withDestinationURL: userApps.appendingPathComponent("Real.app")
        )

        let apps = inventory()

        XCTAssertEqual(apps.map(\.name), ["Real"], "files and .app aliases are not inventory")
    }

    func testBundleWithoutInfoPlistStillInventoried() throws {
        let bundle = try makeApp("Widget", bundleID: nil, version: nil, in: userApps)

        let apps = inventory()

        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].name, "Widget", "folder name is the fallback")
        XCTAssertNil(apps[0].bundleID)
        XCTAssertNil(apps[0].version)
        XCTAssertEqual(canonicalTestPath(apps[0].url), canonicalTestPath(bundle))
    }

    func testMissingRootsYieldEmptyInventory() {
        XCTAssertTrue(inventory().isEmpty)
    }
}
