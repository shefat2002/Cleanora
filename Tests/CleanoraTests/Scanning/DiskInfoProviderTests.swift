import XCTest
@testable import Cleanora

/// DiskInfoProvider — nil-safe volume statistics.
final class DiskInfoProviderTests: XCTestCase {
    func testDefaultConstructorTargetsRootVolume() throws {
        let overview = try XCTUnwrap(DiskInfoProvider().overview())

        XCTAssertGreaterThan(overview.totalCapacity, 0)
        XCTAssertGreaterThanOrEqual(overview.availableForImportantUsage, 0)
        XCTAssertLessThanOrEqual(overview.availableForImportantUsage, overview.totalCapacity)
        XCTAssertGreaterThan(overview.usedBytes, 0)
    }

    func testAvailableBytesMirrorsOverview() throws {
        let provider = DiskInfoProvider()

        XCTAssertEqual(provider.availableBytes(), try XCTUnwrap(provider.overview()).availableForImportantUsage)
    }

    func testInjectedVolumeURLReportsSameVolumeFigures() throws {
        // Any path on the same volume must produce the same statistics —
        // within a tolerance, because APFS free-space figures fluctuate
        // between consecutive queries.
        let tempDir = FileManager.default.temporaryDirectory
        let overview = try XCTUnwrap(DiskInfoProvider(volumeURL: tempDir).overview())
        let root = try XCTUnwrap(DiskInfoProvider(volumeURL: URL(fileURLWithPath: "/")).overview())

        XCTAssertLessThan(
            abs(overview.totalCapacity - root.totalCapacity),
            max(root.totalCapacity / 100, 1)
        )
        XCTAssertLessThan(
            abs(overview.availableForImportantUsage - root.availableForImportantUsage),
            max(root.availableForImportantUsage / 100, 1)
        )
    }

    func testBogusVolumeYieldsNilInsteadOfThrowing() {
        XCTAssertNil(
            DiskInfoProvider(volumeURL: URL(fileURLWithPath: "/nonexistent-cleanora-volume"))
                .overview()
        )
        XCTAssertNil(
            DiskInfoProvider(volumeURL: URL(fileURLWithPath: "/nonexistent-cleanora-volume"))
                .availableBytes()
        )
    }
}
