import XCTest
@testable import Cleanora

final class ByteCountFormattingTests: XCTestCase {
    func testZeroFormats() {
        XCTAssertEqual(Int64(0).formattedByteCount, "0 B")
    }

    func testKilobytesUseOneDecimal() {
        XCTAssertEqual(Int64(999).formattedByteCount, "999 B")
        XCTAssertEqual(Int64(1_000).formattedByteCount, "1.0 KB")
    }

    func testMegabyteBoundary() {
        XCTAssertEqual(Int64(1_000_000).formattedByteCount, "1.0 MB")
    }

    func testGigabyteRange() {
        XCTAssertEqual(Int64(5_800_000_000).formattedByteCount, "5.8 GB")
        XCTAssertEqual(Int64(42_800_000_000).formattedByteCount, "42.8 GB")
    }

    func testNegativeClampsToZero() {
        XCTAssertEqual(Int64(-500).formattedByteCount, "0 B")
    }
}
