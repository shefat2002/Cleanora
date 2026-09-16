import XCTest
@testable import Cleanora

@MainActor
final class DuplicatesViewModelTests: XCTestCase {
    private var dates: [String: Date] = [:]
    private var sizes: [String: Int64] = [:]

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/cleanora-dup-tests/\(name)")
    }

    private func makeViewModel(
        find: @escaping DuplicatesViewModel.FindDuplicates = { _, _, _ in [] }
    ) -> DuplicatesViewModel {
        DuplicatesViewModel(
            findDuplicates: find,
            pickFolder: { nil },
            fileSize: { [sizes] url in sizes[url.path] },
            modificationDate: { [dates] url in dates[url.path] }
        )
    }

    private func group(_ names: [String], wasted: Int64) -> DuplicateGroup {
        DuplicateGroup(files: names.map(url), totalWastedBytes: wasted)
    }

    private func card(
        keeper: String,
        rows: [DuplicatesViewModel.FileRow],
        wasted: Int64 = 10
    ) -> DuplicatesViewModel.DuplicateCard {
        DuplicatesViewModel.DuplicateCard(
            id: UUID(),
            keeperURL: url(keeper),
            wastedBytes: wasted,
            rows: rows
        )
    }

    // MARK: - Scope

    func testAddScopeStandardizesAndAppends() {
        let viewModel = makeViewModel()
        viewModel.addScope(url("folder"))
        viewModel.addScope(URL(fileURLWithPath: "/tmp/cleanora-dup-tests/folder/"))
        XCTAssertEqual(viewModel.scope.count, 1, "the same folder is not added twice")
    }

    func testNestedScopeIsIgnored() {
        let viewModel = makeViewModel()
        viewModel.addScope(url("root"))
        viewModel.addScope(url("root/inner"))
        viewModel.addScope(URL(fileURLWithPath: "/tmp/cleanora-dup-tests"))
        XCTAssertEqual(
            viewModel.scope.map(\.lastPathComponent),
            ["root"],
            "a folder inside an already-scoped folder, and a parent of one, add nothing"
        )
    }

    func testRemoveScope() {
        let viewModel = makeViewModel()
        viewModel.addScope(url("a"))
        viewModel.addScope(url("b"))
        viewModel.removeScope(url("a"))
        XCTAssertEqual(viewModel.scope.map(\.lastPathComponent), ["b"])
    }

    func testCanScanRequiresScope() {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.canScan)
        viewModel.addScope(url("a"))
        XCTAssertTrue(viewModel.canScan)
    }

    // MARK: - Card building

    func testKeeperIsTheEngineSuggestedFirstFile() throws {
        dates = [
            url("old").path: Date(timeIntervalSince1970: 1_000),
            url("new").path: Date(timeIntervalSince1970: 2_000),
        ]
        // Engine contract: files[0] is the keeper — the newest copy.
        let cards = DuplicatesViewModel.buildCards(
            for: [group(["new", "old"], wasted: 10)],
            fileSize: { [sizes] url in sizes[url.path] },
            modificationDate: { [dates] url in dates[url.path] }
        )
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.keeperURL, url("new"))
        XCTAssertEqual(card.rows.first?.url, url("new"), "the keeper leads the group display")
        XCTAssertEqual(card.rows.first?.isKeeper, true)
        XCTAssertEqual(card.rows.filter(\.isKeeper).count, 1)
    }

    func testBuildCardsLeavesEverythingUnselected() throws {
        dates = [
            url("copy1").path: Date(timeIntervalSince1970: 1_000),
            url("copy2").path: Date(timeIntervalSince1970: 3_000),
        ]
        sizes = [url("copy1").path: 1_000, url("copy2").path: 1_000]

        let cards = DuplicatesViewModel.buildCards(
            for: [group(["copy2", "copy1"], wasted: 1_000)],
            fileSize: { [sizes] url in sizes[url.path] },
            modificationDate: { [dates] url in dates[url.path] }
        )

        XCTAssertEqual(cards.count, 1)
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.keeperURL, url("copy2"), "the newest copy is the keeper")
        XCTAssertEqual(card.wastedBytes, 1_000)
        XCTAssertEqual(card.rows.count, 2)
        XCTAssertTrue(card.rows.allSatisfy { !$0.isSelected }, "review rows start unchecked")
        XCTAssertEqual(card.selection, .none)
        let keeperRow = try XCTUnwrap(card.rows.first { $0.isKeeper })
        XCTAssertEqual(keeperRow.url, url("copy2"))
    }

    func testBuildCardsOrdersByWastedBytesAndSkipsDegenerateGroups() {
        dates = [
            url("x1").path: .distantPast,
            url("x2").path: .distantPast,
        ]
        let cards = DuplicatesViewModel.buildCards(
            for: [
                group(["solo"], wasted: 999),
                group(["x1", "x2"], wasted: 100),
                group(["y1", "y2"], wasted: 5_000),
            ],
            fileSize: { _ in 1 },
            modificationDate: { [dates] url in dates[url.path] }
        )
        XCTAssertEqual(cards.count, 2, "a group with a single file is not a duplicate group")
        XCTAssertEqual(cards.map(\.wastedBytes), [5_000, 100], "biggest waste first")
    }

    // MARK: - Selection math

    func testTriStateIgnoresKeeperRow() {
        let group = card(
            keeper: "keeper",
            rows: [
                .init(url: url("keeper"), sizeBytes: 10, modificationDate: nil, isKeeper: true, isSelected: false),
                .init(url: url("d1"), sizeBytes: 10, modificationDate: nil, isKeeper: false, isSelected: false),
                .init(url: url("d2"), sizeBytes: 10, modificationDate: nil, isKeeper: false, isSelected: false),
            ]
        )
        XCTAssertEqual(group.selection, .none)
        XCTAssertEqual(DuplicatesViewModel.targetSelection(for: .none), true)
        XCTAssertEqual(DuplicatesViewModel.targetSelection(for: .some), true)
        XCTAssertEqual(DuplicatesViewModel.targetSelection(for: .all), false)
    }

    func testSelectionAggregatesAcrossCards() async {
        dates = [
            url("k1").path: .distantPast, url("d1").path: .distantPast,
            url("k2").path: .distantPast, url("d2").path: .distantPast,
        ]
        sizes = [url("d1").path: 100, url("d2").path: 300]
        // Built on the main actor BEFORE the @Sendable closure — the closure
        // only captures the Sendable result array.
        let groups = [
            group(["k1", "d1"], wasted: 100),
            group(["k2", "d2"], wasted: 300),
        ]
        let viewModel = makeViewModel(find: { _, _, _ in groups })
        viewModel.addScope(url("scope"))
        viewModel.find()
        let built = await waitUntil { !viewModel.cards.isEmpty }
        XCTAssertTrue(built, "the fake scanner should settle quickly")

        viewModel.setSelection(true, forFile: url("d1"))
        XCTAssertEqual(viewModel.selectedCount, 1)
        XCTAssertEqual(viewModel.selectedBytes, 100)
        XCTAssertTrue(viewModel.canTrash)

        viewModel.setSelection(true, forFile: url("d2"))
        XCTAssertEqual(viewModel.selectedBytes, 400)
        XCTAssertEqual(viewModel.selectedItems.count, 2)
    }

    // MARK: - CleanupItem construction

    func testCleanupItemsCarryReviewTrashAndDuplicateReason() throws {
        let group = card(
            keeper: "original.dmg",
            rows: [
                .init(url: url("keeper"), sizeBytes: 0, modificationDate: nil, isKeeper: true, isSelected: false),
                .init(url: url("copy a"), sizeBytes: 500, modificationDate: nil, isKeeper: false, isSelected: true),
                .init(url: url("copy b"), sizeBytes: 500, modificationDate: nil, isKeeper: false, isSelected: false),
            ],
            wasted: 500
        )

        let items = DuplicatesViewModel.cleanupItems(for: [group])
        XCTAssertEqual(items.count, 1, "only checked rows become cleanup items")
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.name, "copy a", "the item name is the file name")
        XCTAssertEqual(item.category, .largeFiles, "documented label limitation")
        XCTAssertEqual(item.riskLevel, .review)
        XCTAssertEqual(item.deletionMethod, .moveToTrash)
        XCTAssertTrue(item.selected, "checked rows are the confirmed selection")
        XCTAssertEqual(item.size, 500)
        XCTAssertEqual(item.reason, "Duplicate of original.dmg")
        XCTAssertEqual(item.confirmationLevel, .standard)
    }

    // MARK: - Scan flow

    func testFailedSearchSurfacesTheError() async {
        let viewModel = makeViewModel(find: { _, _, _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        })
        viewModel.addScope(url("scope"))
        viewModel.find()
        let settled = await waitUntil { viewModel.phase != .scanning }
        XCTAssertTrue(settled)
        guard case let .failed(message) = viewModel.phase else {
            return XCTFail("expected a failed phase, got \(viewModel.phase)")
        }
        XCTAssertNotEqual(message, "boom", "raw error text must never reach the UI")
        XCTAssertEqual(
            message,
            "The search couldn't finish. Nothing was changed — try again, or pick a different folder."
        )
    }

    func testFailureMessageDistinguishesPermissionErrors() {
        let cocoaDenied = DuplicatesViewModel.failureMessage(
            for: CocoaError(.fileReadNoPermission)
        )
        XCTAssertTrue(
            cocoaDenied.contains("Full Disk Access"),
            "permission failures must name the fix"
        )

        let posixDenied = DuplicatesViewModel.failureMessage(
            for: POSIXError(.EACCES)
        )
        XCTAssertTrue(
            posixDenied.contains("Full Disk Access"),
            "permission failures must name the fix"
        )

        let other = DuplicatesViewModel.failureMessage(
            for: NSError(domain: "test", code: 1)
        )
        XCTAssertFalse(
            other.contains("Full Disk Access"),
            "non-permission failures must not send the user hunting settings"
        )
    }

    func testCancellationLeavesNothingBehind() async {
        let viewModel = makeViewModel(find: { _, _, _ in
            throw CancellationError()
        })
        viewModel.addScope(url("scope"))
        viewModel.find()
        let settled = await waitUntil { viewModel.phase != .scanning }
        XCTAssertTrue(settled)
        XCTAssertEqual(viewModel.phase, .cancelled)
        XCTAssertTrue(viewModel.cards.isEmpty)
    }

    func testProgressAccumulatesMonotonically() async {
        let viewModel = makeViewModel(find: { _, _, onProgress in
            onProgress(DuplicateProgress(filesExamined: 10, bytesExamined: 0, duplicateGroupsFound: 1))
            onProgress(DuplicateProgress(filesExamined: 4, bytesExamined: 0, duplicateGroupsFound: 0))
            return []
        })
        viewModel.addScope(url("scope"))
        viewModel.find()
        let settled = await waitUntil { viewModel.phase == .finished }
        XCTAssertTrue(settled)
        XCTAssertEqual(viewModel.filesExamined, 10, "out-of-order progress never runs backwards")
        XCTAssertEqual(viewModel.groupsFound, 1)
    }

    // MARK: - Reconciliation

    func testReconciliationDropsRemovedFilesAndKeepsGroup() throws {
        dates = [
            url("k").path: .distantPast,
            url("gone").path: .distantPast,
            url("kept").path: .distantPast,
        ]
        let group = card(
            keeper: "k",
            rows: [
                .init(url: url("k"), sizeBytes: 0, modificationDate: nil, isKeeper: true, isSelected: false),
                .init(url: url("gone"), sizeBytes: 100, modificationDate: nil, isKeeper: false, isSelected: true),
                .init(url: url("kept"), sizeBytes: 100, modificationDate: nil, isKeeper: false, isSelected: false),
            ],
            wasted: 100
        )

        let item = try XCTUnwrap(DuplicatesViewModel.cleanupItems(for: [group]).first)
        let report = CleanupReport(
            startedAt: Date(),
            finishedAt: Date(),
            outcomes: [VMFixtures.outcome(for: item, status: .removed, bytesFreed: 100)],
            freeSpaceBefore: nil,
            freeSpaceAfter: nil,
            scanResultID: nil
        )

        let outcome = DuplicatesViewModel.reconciling(cards: [group], report: report) { _ in true }
        XCTAssertEqual(outcome.removedCount, 1)
        XCTAssertEqual(outcome.freedBytes, 100)
        let reconciled = try XCTUnwrap(outcome.cards.first)
        XCTAssertEqual(reconciled.rows.map(\.url), [url("k"), url("kept")], "removed copy disappears")
        XCTAssertFalse(reconciled.rows[1].isSelected, "untouched rows keep their unchecked state")
    }

    func testReconciliationPrunesGroupsBelowTwoFiles() throws {
        dates = [url("k").path: .distantPast, url("only").path: .distantPast]
        let group = card(
            keeper: "k",
            rows: [
                .init(url: url("k"), sizeBytes: 0, modificationDate: nil, isKeeper: true, isSelected: false),
                .init(url: url("only"), sizeBytes: 10, modificationDate: nil, isKeeper: false, isSelected: true),
            ],
            wasted: 10
        )
        let item = try XCTUnwrap(DuplicatesViewModel.cleanupItems(for: [group]).first)
        let report = CleanupReport(
            startedAt: Date(),
            finishedAt: Date(),
            outcomes: [VMFixtures.outcome(for: item, status: .removed, bytesFreed: 10)],
            freeSpaceBefore: nil,
            freeSpaceAfter: nil,
            scanResultID: nil
        )
        let outcome = DuplicatesViewModel.reconciling(cards: [group], report: report) { _ in true }
        XCTAssertTrue(outcome.cards.isEmpty, "keeper + zero duplicates is not a group anymore")
    }

    func testReconciliationCollectsRefusals() throws {
        dates = [url("k").path: .distantPast, url("outside").path: .distantPast]
        let group = card(
            keeper: "k",
            rows: [
                .init(url: url("k"), sizeBytes: 0, modificationDate: nil, isKeeper: true, isSelected: false),
                .init(url: url("outside"), sizeBytes: 10, modificationDate: nil, isKeeper: false, isSelected: true),
            ],
            wasted: 10
        )
        let item = try XCTUnwrap(DuplicatesViewModel.cleanupItems(for: [group]).first)
        let report = CleanupReport(
            startedAt: Date(),
            finishedAt: Date(),
            outcomes: [
                VMFixtures.outcome(
                    for: item,
                    status: .skipped,
                    bytesFreed: 0,
                    message: "Refused: path is outside the allowed cleanup roots"
                )
            ],
            freeSpaceBefore: nil,
            freeSpaceAfter: nil,
            scanResultID: nil
        )
        let outcome = DuplicatesViewModel.reconciling(cards: [group], report: report) { _ in true }
        XCTAssertEqual(outcome.removedCount, 0)
        XCTAssertEqual(outcome.refusedMessages.count, 1)
        XCTAssertEqual(
            DuplicatesViewModel.reconciliationLine(
                removed: outcome.removedCount,
                refused: outcome.refusedMessages.count,
                freedBytes: outcome.freedBytes,
                refusedMessages: outcome.refusedMessages
            ),
            "1 refused by the safety gate."
        )
    }

    func testReconciliationLine() {
        XCTAssertNil(DuplicatesViewModel.reconciliationLine(
            removed: 0, refused: 0, freedBytes: 0, refusedMessages: []
        ))
        XCTAssertEqual(
            DuplicatesViewModel.reconciliationLine(
                removed: 1, refused: 0, freedBytes: 2_000_000_000, refusedMessages: []
            ),
            "1 item moved to Trash, 2.0 GB freed."
        )
        XCTAssertEqual(
            DuplicatesViewModel.reconciliationLine(
                removed: 2, refused: 1, freedBytes: 10, refusedMessages: ["x"]
            ),
            "2 items moved to Trash, 10 B freed — 1 refused by the safety gate."
        )
    }

    func testProgressLineReflectsGroupsFound() {
        XCTAssertNil(DuplicatesViewModel.progressLine(filesExamined: 0, groupsFound: 0))
        XCTAssertEqual(
            DuplicatesViewModel.progressLine(filesExamined: 5, groupsFound: 0),
            "Checked 5 files…"
        )
        XCTAssertEqual(
            DuplicatesViewModel.progressLine(filesExamined: 5, groupsFound: 2),
            "Checked 5 files — 2 groups found so far…"
        )
    }
}
