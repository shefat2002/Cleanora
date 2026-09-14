import XCTest
@testable import Cleanora

final class ScanEnvironmentTests: TempHomeTestCase {
    func testDerivedPathsLiveUnderInjectedHome() {
        XCTAssertEqual(environment.caches.path, tempHome.appendingPathComponent("Library/Caches").path)
        XCTAssertEqual(environment.logs.path, tempHome.appendingPathComponent("Library/Logs").path)
        XCTAssertEqual(environment.trash.path, tempHome.appendingPathComponent(".Trash").path)
        XCTAssertEqual(environment.temporaryRoot.path, tempRoot.path)
    }

    func testExistsAndReadable() throws {
        let file = tempHome.appendingPathComponent("present.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertTrue(environment.exists(file))
        XCTAssertTrue(environment.readable(file))
        XCTAssertFalse(environment.exists(tempHome.appendingPathComponent("missing.txt")))
    }

    func testLiveEnvironmentUsesRealHome() {
        let live = ScanEnvironment.live()
        XCTAssertEqual(live.home, FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertTrue(live.exists(live.home))
    }

    // MARK: - Phase 3: applications root (M-06)

    func testApplicationsDefaultsToTheSystemApplicationsFolder() {
        XCTAssertEqual(
            environment.applications.standardizedFileURL.path,
            URL(fileURLWithPath: "/Applications", isDirectory: true).standardizedFileURL.path
        )
    }

    func testApplicationsOverrideIsInjectableForTests() {
        let override = tempHome.appendingPathComponent("OverrideApps", isDirectory: true)
        let custom = ScanEnvironment(
            home: tempHome,
            temporaryRoot: tempRoot,
            applicationsOverride: override
        )
        XCTAssertEqual(custom.applications, override)
        // The default environment is untouched by the new parameter.
        XCTAssertEqual(
            ScanEnvironment(home: tempHome, temporaryRoot: tempRoot).applications,
            ScanEnvironment.systemApplications
        )
    }

    func testUserApplicationsFolderIsDerivedFromHome() {
        XCTAssertEqual(
            environment.userApplications.path,
            tempHome.appendingPathComponent("Applications").path
        )
    }
}
