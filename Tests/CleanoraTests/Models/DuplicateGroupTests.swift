import XCTest
@testable import Cleanora

/// M-04 model — a DuplicateGroup carries the member files (keeper first)
/// and the space the DUPLICATE copies waste.
final class DuplicateGroupTests: XCTestCase {
    func testEquatableComparesFilesAndWastedBytes() {
        let files = [URL(fileURLWithPath: "/tmp/a.dat"), URL(fileURLWithPath: "/tmp/b.dat")]
        let group = DuplicateGroup(files: files, totalWastedBytes: 1_000_000)

        XCTAssertEqual(group, DuplicateGroup(files: files, totalWastedBytes: 1_000_000))
        XCTAssertNotEqual(
            group,
            DuplicateGroup(files: files, totalWastedBytes: 2_000_000)
        )
        XCTAssertNotEqual(
            group,
            DuplicateGroup(files: [files[0]], totalWastedBytes: 1_000_000)
        )
    }

    func testSingleFileGroupWastesNothing() {
        let group = DuplicateGroup(
            files: [URL(fileURLWithPath: "/tmp/only.dat")],
            totalWastedBytes: 0
        )
        XCTAssertEqual(group.totalWastedBytes, 0)
    }
}
