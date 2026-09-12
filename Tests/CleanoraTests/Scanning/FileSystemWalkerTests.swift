import XCTest
import os
@testable import Cleanora

/// E-03 — FileSystemWalker: child URLs, depth cap, time budget,
/// cancellation per directory, symlink shyness (I7).
final class FileSystemWalkerTests: TempHomeTestCase {
    private let fileManager = FileManager.default

    private func makeNestedTree() throws -> URL {
        let root = tempHome.appendingPathComponent("nested", isDirectory: true)
        try FixtureBuilder.makeTree(in: root, [
            ("a.txt", 10),
            ("l1/b.txt", 10),
            ("l1/l2/c.txt", 10),
            ("l1/l2/l3/d.txt", 10),
            ("l1/l2/l3/l4/e.txt", 10),
        ])
        return root
    }

    private func names(_ urls: [URL]) -> [String] {
        urls.map(\.lastPathComponent).sorted()
    }

    // MARK: - children(of:)

    func testChildrenReturnsDirectChildrenOnlyIncludingHidden() throws {
        let dir = tempHome.appendingPathComponent("flat", isDirectory: true)
        try FixtureBuilder.makeTree(in: dir, [
            ("visible.txt", 10),
            ("sub/inner.txt", 10),
            (".hidden", 10),
        ])

        let children = try FileSystemWalker().children(of: dir)

        XCTAssertEqual(names(children), [".hidden", "sub", "visible.txt"])
    }

    func testChildrenThrowsForUnreadableDirectory() throws {
        try XCTSkipUnless(getuid() != 0, "chmod-based unreadability does not apply to root")
        let dir = tempHome.appendingPathComponent("locked", isDirectory: true)
        try FixtureBuilder.makeTree(in: dir, [("secret.txt", 10)])
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        XCTAssertThrowsError(try FileSystemWalker().children(of: dir))
    }

    // MARK: - descendants(of:)

    func testDescendantsReturnsAllEntriesBelowRoot() throws {
        let root = try makeNestedTree()

        let report = FileSystemWalker().descendants(of: root)

        XCTAssertEqual(report.entries.count, 9) // 5 files + 4 directories
        XCTAssertFalse(report.hitTimeBudget)
    }

    func testDescendantsHonorsDepthCap() throws {
        let root = try makeNestedTree()

        let report = FileSystemWalker().descendants(
            of: root,
            options: FileSystemWalker.Options(maxDepth: 2)
        )

        // Depth 1 (a.txt, l1) + depth 2 (b.txt, l2) only.
        XCTAssertEqual(names(report.entries), ["a.txt", "b.txt", "l1", "l2"])
    }

    func testDescendantsReportsTimeBudgetExceeded() throws {
        let root = try makeNestedTree()

        let report = FileSystemWalker().descendants(
            of: root,
            options: FileSystemWalker.Options(timeBudget: 0)
        )

        XCTAssertTrue(report.hitTimeBudget)
        XCTAssertTrue(report.entries.isEmpty)
    }

    func testDescendantsGenerousBudgetWalksEverything() throws {
        let root = try makeNestedTree()

        let report = FileSystemWalker().descendants(
            of: root,
            options: FileSystemWalker.Options(timeBudget: 60)
        )

        XCTAssertEqual(report.entries.count, 9)
        XCTAssertFalse(report.hitTimeBudget)
    }

    func testDescendantsDoesNotDescendIntoSymlinkedDirectories() throws {
        let outsideDir = tempRoot.appendingPathComponent("outside-walker", isDirectory: true)
        try FixtureBuilder.makeTree(in: outsideDir, [("heavy.bin", 100_000)])

        let root = tempHome.appendingPathComponent("linked", isDirectory: true)
        try FixtureBuilder.makeTree(in: root, [("real.txt", 10)])
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("linked-dir"),
            withDestinationURL: outsideDir
        )

        let report = FileSystemWalker().descendants(of: root)

        // The link itself is reported; its target's contents never are.
        XCTAssertEqual(names(report.entries), ["linked-dir", "real.txt"])
        XCTAssertTrue(fileManager.fileExists(atPath: outsideDir.appendingPathComponent("heavy.bin").path))
    }

    func testDescendantsSkipsUnreadableSubdirectoriesWithoutFailing() throws {
        try XCTSkipUnless(getuid() != 0, "chmod-based unreadability does not apply to root")
        let root = tempHome.appendingPathComponent("mixed", isDirectory: true)
        try FixtureBuilder.makeTree(in: root, [
            ("ok.txt", 10),
            ("locked/secret.txt", 10),
        ])
        let locked = root.appendingPathComponent("locked")
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let report = FileSystemWalker().descendants(of: root)

        XCTAssertEqual(names(report.entries), ["locked", "ok.txt"])
    }

    // MARK: - Cancellation per directory

    func testDescendantsStopsWhenShouldContinueTurnsFalse() throws {
        let root = try makeNestedTree()
        let gate = WalkerGate(allowedCalls: 2)

        let report = FileSystemWalker().descendants(of: root, shouldContinue: { gate.keepGoing() })

        XCTAssertLessThan(report.entries.count, 9)
    }

    func testDescendantsReturnsNothingWhenCancelledFromTheStart() throws {
        let root = try makeNestedTree()

        let report = FileSystemWalker().descendants(of: root, shouldContinue: { false })

        XCTAssertTrue(report.entries.isEmpty)
    }

    func testDescendantsCancelledTaskYieldsPartial() async throws {
        let root = tempHome.appendingPathComponent("wide-walker", isDirectory: true)
        var entries: [(String, Int)] = []
        for index in 0..<3_000 {
            entries.append(("dir-\(String(format: "%04d", index))/file.bin", 1))
        }
        try FixtureBuilder.makeTree(in: root, entries)

        let task = Task {
            FileSystemWalker().descendants(of: root)
        }
        task.cancel()
        let report = await task.value

        XCTAssertLessThan(report.entries.count, entries.count * 2)
    }
}

/// Same gate helper as the calculator tests, kept local to this file's scope.
private final class WalkerGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    private let allowedCalls: Int

    init(allowedCalls: Int) {
        self.allowedCalls = allowedCalls
    }

    func keepGoing() -> Bool {
        state.withLock { count in
            count += 1
            return count <= allowedCalls
        }
    }
}
