import XCTest
import os
@testable import Cleanora

/// Permission canaries (task K-05). Probes use contentsOfDirectory — TCC
/// blocks enumeration, not stat, so isReadableFile would lie. Detection
/// logic is unit-tested on fixtures; the deep link stays behind an injected
/// closure so no test ever launches System Settings.
final class PermissionManagerTests: TempHomeTestCase {
    private let fileManager = FileManager.default

    private func makeManager(
        openSettings: (@Sendable () -> Void)? = nil
    ) -> PermissionManager {
        PermissionManager(
            home: tempHome,
            openSettings: openSettings ?? {}
        )
    }

    private func makeSafariDir() throws -> URL {
        let safari = tempHome.appendingPathComponent("Library/Safari", isDirectory: true)
        try fileManager.createDirectory(at: safari, withIntermediateDirectories: true)
        return safari
    }

    func testReadableAreasReportAllowed() throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        try makeSafariDir()

        let status = makeManager().probe()

        XCTAssertEqual(status.caches, .allowed)
        XCTAssertEqual(status.logs, .allowed)
        XCTAssertEqual(status.trash, .allowed)
        XCTAssertEqual(status.safari, .allowed)
        XCTAssertTrue(status.isComplete)
        XCTAssertTrue(status.deniedAreas.isEmpty)
    }

    func testMissingAreaReportsMissing() throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        // Library/Safari intentionally absent.

        let status = makeManager().probe()

        XCTAssertEqual(status.safari, .missing)
        XCTAssertFalse(status.isComplete)
        XCTAssertEqual(status.deniedAreas, ["Safari"])
    }

    func testUnreadableAreaReportsPermissionDenied() throws {
        try FixtureBuilder.makeHomeSkeleton(in: tempHome)
        let safari = try makeSafariDir()
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: safari.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safari.path)
        }

        let status = makeManager().probe()

        XCTAssertEqual(status.safari, .permissionDenied,
                       "enumeration of a TCC-blocked directory fails with no-permission")
        XCTAssertFalse(status.isComplete)
        XCTAssertEqual(status.deniedAreas, ["Safari"])
    }

    func testOpenSettingsGoesThroughInjectedClosure() {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let manager = makeManager(openSettings: { calls.withLock { $0 += 1 } })

        manager.openFullDiskAccessSettings()
        manager.openFullDiskAccessSettings()

        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testFullDiskAccessDeepLinkConstant() {
        XCTAssertEqual(
            PermissionManager.fullDiskAccessSettingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
    }
}
