import XCTest
@testable import Cleanora

/// Base class for engine tests: provides an isolated fake $HOME and a
/// matching ScanEnvironment, so nothing ever touches the real user home.
class TempHomeTestCase: XCTestCase {
    var tempHome: URL!
    var tempRoot: URL!
    var environment: ScanEnvironment!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanora-tests-\(UUID().uuidString)", isDirectory: true)
        tempHome = base.appendingPathComponent("home", isDirectory: true)
        tempRoot = base.appendingPathComponent("temp", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        environment = ScanEnvironment(home: tempHome, temporaryRoot: tempRoot)
    }

    override func tearDownWithError() throws {
        if let base = tempHome?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: base)
        }
        tempHome = nil
        tempRoot = nil
        environment = nil
        try super.tearDownWithError()
    }
}
