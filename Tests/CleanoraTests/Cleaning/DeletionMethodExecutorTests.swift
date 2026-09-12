import XCTest
import os
@testable import Cleanora

/// DeletionMethodExecutor semantics (task K-02):
/// - trash methods go through the injected TrashMove (the default is
///   FileManager.trashItem, which always targets the REAL user Trash — tests
///   must never invoke it, so they stand in a fixture .Trash)
/// - removeContents deletes children, keeps the parent
/// - items already inside ~/.Trash are removed in place, never re-trashed
/// - every failure is an outcome, nothing ever throws past the caller (I11)
final class DeletionMethodExecutorTests: TempHomeTestCase {
    private var trashDir: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        trashDir = tempHome.appendingPathComponent(".Trash", isDirectory: true)
        try fileManager.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }

    private func makeItem(
        path: URL,
        method: DeletionMethod,
        risk: RiskLevel = .safe
    ) -> CleanupItem {
        CleanupItem(
            name: path.lastPathComponent,
            category: .applicationCaches,
            path: path,
            size: 0,
            riskLevel: risk,
            reason: "test",
            deletionMethod: method
        )
    }

    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    /// Moves the item into the fixture's .Trash, mirroring trashItem
    /// semantics without touching the real user home.
    private func fixtureTrashExecutor(
        throws failure: Error? = nil
    ) -> DeletionMethodExecutor {
        let destinationRoot = trashDir!
        return DeletionMethodExecutor(trashMove: { url in
            if let failure { throw failure }
            let destination = destinationRoot.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
    }

    // MARK: - Trash methods

    func testTrashDirectoryMovesDirectoryIntoTrash() throws {
        let dir = tempHome.appendingPathComponent("Library/Caches/com.example.app")
        try FixtureBuilder.makeTree(in: dir, [("blob.bin", 128)])
        let item = makeItem(path: dir, method: .trashDirectory)

        let result = fixtureTrashExecutor().delete(item, home: tempHome)

        XCTAssertEqual(result.kind, .removed)
        XCTAssertFalse(exists(dir), "item must be gone from its original path")
        XCTAssertTrue(exists(trashDir.appendingPathComponent("com.example.app")),
                      "item must be recoverable in the Trash")
    }

    func testMoveToTrashMovesSingleFile() throws {
        let file = tempHome.appendingPathComponent("Library/Logs/app.log")
        try FixtureBuilder.makeTree(in: file.deletingLastPathComponent(), [("app.log", 64)])
        let item = makeItem(path: file, method: .moveToTrash)

        let result = fixtureTrashExecutor().delete(item, home: tempHome)

        XCTAssertEqual(result.kind, .removed)
        XCTAssertFalse(exists(file))
        XCTAssertTrue(exists(trashDir.appendingPathComponent("app.log")))
    }

    // Recoverable-by-contract: a refused trash move must never fall back to
    // a permanent rm (external-volume trashItem failures land here).
    func testTrashMoveFailureLeavesItemInPlaceAndReportsFailed() throws {
        let file = tempHome.appendingPathComponent("Library/Logs/app.log")
        try FixtureBuilder.makeTree(in: file.deletingLastPathComponent(), [("app.log", 64)])
        let item = makeItem(path: file, method: .moveToTrash)
        let refusal = NSError(
            domain: "CleanoraTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "volume does not support trash"]
        )

        let result = fixtureTrashExecutor(throws: refusal).delete(item, home: tempHome)

        XCTAssertEqual(result.kind, .failed)
        XCTAssertTrue(exists(file), "failed trash move must never silently rm the item")
        XCTAssertNotNil(result.message)
    }

    // MARK: - removeContents

    func testRemoveContentsRemovesChildrenButKeepsParent() throws {
        let dir = tempHome.appendingPathComponent("Library/Caches/com.example.app")
        try FixtureBuilder.makeTree(in: dir, [
            ("visible.dat", 64), ("nested/deep.dat", 32), (".hidden", 8),
        ])

        let result = fixtureTrashExecutor().delete(
            makeItem(path: dir, method: .removeContents), home: tempHome
        )

        XCTAssertEqual(result.kind, .removed)
        XCTAssertTrue(exists(dir), "the cache root must survive a content wipe")
        XCTAssertFalse(exists(dir.appendingPathComponent("visible.dat")))
        XCTAssertFalse(exists(dir.appendingPathComponent("nested/deep.dat")))
        XCTAssertFalse(exists(dir.appendingPathComponent(".hidden")),
                       "hidden entries are contents too")
    }

    func testRemoveContentsReportsPartialOrFailedFromRemainingChildren() throws {
        // partial: some children go, one locked subtree refuses
        let partialDir = tempHome.appendingPathComponent("Library/Caches/partial")
        try FixtureBuilder.makeTree(in: partialDir, [("gone.dat", 64), ("locked/stuck.dat", 32)])
        let locked = partialDir.appendingPathComponent("locked")
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let partial = fixtureTrashExecutor().delete(
            makeItem(path: partialDir, method: .removeContents), home: tempHome
        )
        XCTAssertEqual(partial.kind, .partial)
        XCTAssertFalse(exists(partialDir.appendingPathComponent("gone.dat")))
        XCTAssertTrue(exists(locked.appendingPathComponent("stuck.dat")))

        // failed: every child refuses, nothing was removed
        let failedDir = tempHome.appendingPathComponent("Library/Caches/failed")
        try FixtureBuilder.makeTree(in: failedDir, [("locked/stuck.dat", 32)])
        let lockedChild = failedDir.appendingPathComponent("locked")
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedChild.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedChild.path) }

        let failed = fixtureTrashExecutor().delete(
            makeItem(path: failedDir, method: .removeContents), home: tempHome
        )
        XCTAssertEqual(failed.kind, .failed)
        XCTAssertTrue(exists(lockedChild.appendingPathComponent("stuck.dat")))
    }

    // MARK: - Items already inside ~/.Trash

    // trashItem on an in-Trash path errors; the executor must route to
    // in-place content removal instead.
    func testItemInsideTrashIsRemovedInPlaceWithoutATrashMove() throws {
        let junk = trashDir.appendingPathComponent("junk")
        try FixtureBuilder.makeTree(in: junk, [("j.dat", 16)])
        let trashMoveCalls = OSAllocatedUnfairLock(initialState: 0)
        let executor = DeletionMethodExecutor(trashMove: { url in
            trashMoveCalls.withLock { $0 += 1 }
            return url
        })
        let item = CleanupItem(
            name: "junk", category: .trash, path: junk, size: 16,
            riskLevel: .safe, reason: "test",
            deletionMethod: .trashDirectory, confirmationLevel: .destructive
        )

        let result = executor.delete(item, home: tempHome)

        XCTAssertEqual(result.kind, .removed)
        XCTAssertEqual(trashMoveCalls.withLock { $0 }, 0, "in-Trash items must never be re-trashed")
        XCTAssertFalse(exists(junk.appendingPathComponent("j.dat")))
        XCTAssertTrue(exists(junk), "content removal keeps the parent")
    }

    // I7 for the deletion layer: a symlink child is unlinked, its target
    // stays untouched.
    func testSymlinkChildIsRemovedWithoutFollowingTarget() throws {
        let target = tempRoot.appendingPathComponent("precious.txt")
        try Data(repeating: 0x42, count: 32).write(to: target)
        let dir = tempHome.appendingPathComponent("Library/Caches/linker")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: dir.appendingPathComponent("escape"),
            withDestinationURL: target
        )

        let result = fixtureTrashExecutor().delete(
            makeItem(path: dir, method: .removeContents), home: tempHome
        )

        XCTAssertEqual(result.kind, .removed)
        XCTAssertFalse(exists(dir.appendingPathComponent("escape")))
        XCTAssertTrue(exists(target), "symlink target must never be followed")
        XCTAssertEqual(try Data(contentsOf: target).count, 32)
    }

    // MARK: - Missing paths

    func testMissingPathReportsAlreadyGoneAndFileWithRemoveContentsIsRemoved() throws {
        let gone = tempHome.appendingPathComponent("Library/Caches/vanished")
        let alreadyGone = fixtureTrashExecutor().delete(
            makeItem(path: gone, method: .removeContents), home: tempHome
        )
        XCTAssertEqual(alreadyGone.kind, .alreadyGone)

        // A file (not a directory) marked removeContents is removed itself.
        let file = tempHome.appendingPathComponent("Library/Logs/single.log")
        try FixtureBuilder.makeTree(in: file.deletingLastPathComponent(), [("single.log", 16)])
        let singleFile = fixtureTrashExecutor().delete(
            makeItem(path: file, method: .removeContents), home: tempHome
        )
        XCTAssertEqual(singleFile.kind, .removed)
        XCTAssertFalse(exists(file))
    }
}
