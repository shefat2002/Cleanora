import XCTest
@testable import Cleanora

@MainActor
final class ResultsViewModelTests: XCTestCase {
    // MARK: Selection defaults

    func testReviewItemsAreNeverPreselectedEvenIfEngineMisbehaves() {
        let safe = VMFixtures.item(name: "Chrome", category: .applicationCaches, size: 100, risk: .safe)
        let review = VMFixtures.item(name: "Big Archive", category: .applicationCaches, size: 500, risk: .review)
        let crafted = VMFixtures.item(name: "Bad Producer", category: .logs, size: 10, risk: .review, selected: true)
        let viewModel = ResultsViewModel(result: VMFixtures.scanResult(items: [safe, review, crafted]))

        XCTAssertEqual(viewModel.selectedItems.map(\.name), ["Chrome"], "review items must start unselected")
        XCTAssertEqual(viewModel.selectedBytes, 100)
        XCTAssertTrue(viewModel.canClean)
    }

    // MARK: Tri-state selection

    func testCategoryTriStateTransitions() {
        let items = [
            VMFixtures.item(name: "A", category: .applicationCaches, size: 10, risk: .safe),
            VMFixtures.item(name: "B", category: .applicationCaches, size: 20, risk: .safe),
            VMFixtures.item(name: "C", category: .applicationCaches, size: 30, risk: .review),
        ]
        let viewModel = ResultsViewModel(result: VMFixtures.scanResult(items: items))

        let section = viewModel.sections[0]
        XCTAssertEqual(section.category, .applicationCaches)
        XCTAssertEqual(section.selection, .some, "safe preselected + review unselected = mixed")
        XCTAssertTrue(ResultsViewModel.targetSelection(for: .some), "mixed click selects all")

        viewModel.setCategorySelection(.applicationCaches, isSelected: true)
        XCTAssertEqual(viewModel.sections[0].selection, .all)
        XCTAssertEqual(viewModel.selectedBytes, 60)
        XCTAssertEqual(viewModel.selectedCount, 3)

        viewModel.setCategorySelection(.applicationCaches, isSelected: false)
        XCTAssertEqual(viewModel.sections[0].selection, .none)
        XCTAssertEqual(viewModel.selectedBytes, 0)
        XCTAssertFalse(viewModel.canClean, "Clean enables only when selectedBytes > 0")
    }

    func testItemToggleUpdatesInstantTotalsAndSections() {
        let a = VMFixtures.item(name: "A", category: .logs, size: 100, risk: .safe)
        let b = VMFixtures.item(name: "B", category: .logs, size: 50, risk: .safe)
        let viewModel = ResultsViewModel(result: VMFixtures.scanResult(items: [a, b]))

        viewModel.setSelection(false, itemID: a.id)
        XCTAssertEqual(viewModel.selectedBytes, 50)
        XCTAssertEqual(viewModel.sections[0].selectedBytes, 50, "sections rebuild from the same source of truth")
        XCTAssertEqual(ResultsViewModel.selectionState(of: viewModel.sections[0].items), .some)
    }

    func testGroupSelectionAffectsOnlyItsItems() {
        let chrome = VMFixtures.item(name: "Default", category: .browserCaches, size: 900, risk: .safe, appName: "Chrome")
        let safari = VMFixtures.item(name: "Profiles", category: .browserCaches, size: 800, risk: .safe, appName: "Safari")
        let viewModel = ResultsViewModel(result: VMFixtures.scanResult(items: [chrome, safari]))

        let group = viewModel.sections[0].groups.first { $0.name == "Chrome" }!
        viewModel.setSelection(false, itemIDs: group.itemIDs)
        XCTAssertEqual(viewModel.selectedBytes, 800)
        let chromeGroup = viewModel.sections[0].groups.first { $0.name == "Chrome" }!
        XCTAssertEqual(chromeGroup.selectedBytes, 0)
        XCTAssertEqual(ResultsViewModel.selectionState(of: chromeGroup.items), .none)
    }

    // MARK: App grouping + Other rollup

    func testOtherRollupFoldsSmallAppsAndUnnamedItems() {
        let mega = 1_000_000_000
        let items = [
            VMFixtures.item(name: "Chrome", category: .applicationCaches, size: Int64(2100 * 1_000_000), risk: .safe, appName: "Chrome"),
            VMFixtures.item(name: "Xcode", category: .applicationCaches, size: Int64(1700 * 1_000_000), risk: .safe, appName: "Xcode"),
            VMFixtures.item(name: "VS Code", category: .applicationCaches, size: Int64(900 * 1_000_000), risk: .safe, appName: "VS Code"),
            VMFixtures.item(name: "tiny1", category: .applicationCaches, size: 50_000_000, risk: .safe, appName: "Tiny1"),
            VMFixtures.item(name: "tiny2", category: .applicationCaches, size: 40_000_000, risk: .safe, appName: "Tiny2"),
            VMFixtures.item(name: "unnamed", category: .applicationCaches, size: 30_000_000, risk: .safe),
        ]
        let viewModel = ResultsViewModel(result: VMFixtures.scanResult(items: items))
        let groups = viewModel.sections[0].groups

        XCTAssertEqual(groups.map(\.name), ["Chrome", "Xcode", "VS Code", "Other"], "big apps first, Other last")
        // 5% of 4.82 GB = 241 MB: Tiny1 and Tiny2 fold in, named items don't.
        let other = groups.last!
        XCTAssertEqual(other.items.map(\.name).sorted(), ["tiny1", "tiny2", "unnamed"])
        XCTAssertEqual(other.bytes, 120_000_000)
    }

    func testSingleNamedAppKeepsItsGroupAlongsideOther() {
        let only = VMFixtures.item(name: "Cache", category: .applicationCaches, size: 100, risk: .safe, appName: "Solo")
        let unnamed = VMFixtures.item(name: "Cache2", category: .applicationCaches, size: 50, risk: .safe)
        let viewModel = ResultsViewModel(result: VMFixtures.scanResult(items: [only, unnamed]))
        // Even a lone named app keeps its group so the app name stays
        // visible; unnamed leftovers collect under "Other".
        XCTAssertEqual(viewModel.sections[0].groups.map(\.name), ["Solo", "Other"])
    }

    func testFullyUnnamedCategoryRendersFlat() {
        let a = VMFixtures.item(name: "A", category: .temporaryFiles, size: 100, risk: .safe)
        let b = VMFixtures.item(name: "B", category: .temporaryFiles, size: 50, risk: .safe)
        let viewModel = ResultsViewModel(result: VMFixtures.scanResult(items: [a, b]))
        XCTAssertTrue(viewModel.sections[0].groups.isEmpty, "no app names anywhere = flat item list")
    }

    func testSortedItemsSafeFirstThenBySize() {
        let reviewBig = VMFixtures.item(name: "Archive", category: .largeFiles, size: 900, risk: .review)
        let safeSmall = VMFixtures.item(name: "cache", category: .largeFiles, size: 10, risk: .safe)
        let safeBig = VMFixtures.item(name: "Cache", category: .largeFiles, size: 800, risk: .safe)
        let sorted = ResultsViewModel.sortedItems([reviewBig, safeSmall, safeBig])
        XCTAssertEqual(sorted.map(\.name), ["Cache", "cache", "Archive"])
    }

    // MARK: Confirmation prerequisites

    func testRequiresDestructiveConfirmationTracksSelection() {
        let trash = VMFixtures.item(
            name: "Trash",
            category: .trash,
            size: 2_000_000_000,
            risk: .safe,
            confirmationLevel: .destructive,
            deletionMethod: .removeContents
        )
        let review = VMFixtures.item(name: "Archive", category: .applicationCaches, size: 100, risk: .review)
        let viewModel = ResultsViewModel(result: VMFixtures.scanResult(items: [trash, review]))

        XCTAssertTrue(viewModel.requiresDestructiveConfirmation, "selected trash forces the irreversible step")

        viewModel.setSelection(false, itemID: trash.id)
        XCTAssertFalse(viewModel.requiresDestructiveConfirmation)

        viewModel.setSelection(true, itemID: review.id)
        XCTAssertFalse(viewModel.requiresDestructiveConfirmation, "plain review items are not destructive")
    }

    func testConfirmGroupsSortByCategoryOrderAndSize() {
        let trash = VMFixtures.item(name: "Trash", category: .trash, size: 100, risk: .safe, confirmationLevel: .destructive)
        let logs = VMFixtures.item(name: "Log", category: .logs, size: 300, risk: .safe)
        let logsBig = VMFixtures.item(name: "Big Log", category: .logs, size: 900, risk: .safe)
        let viewModel = ResultsViewModel(result: VMFixtures.scanResult(items: [trash, logs, logsBig]))
        viewModel.setSelection(true, itemID: trash.id)

        let groups = ResultsViewModel.confirmGroups(for: viewModel.selectedItems)
        XCTAssertEqual(groups.map(\.category), [.logs, .trash])
        XCTAssertEqual(groups[0].items.map(\.name), ["Big Log", "Log"])
    }

    func testEmptyResultIsEmpty() {
        let viewModel = ResultsViewModel(result: VMFixtures.scanResult(items: []))
        XCTAssertTrue(viewModel.isEmpty)
        XCTAssertFalse(viewModel.canClean)
    }

    // MARK: Cancelled-cleanup reconciliation (backlog fix)

    func testReconciliationDropsMissingFilesAndCountsThem() {
        let kept = VMFixtures.item(name: "Kept", category: .logs, size: 100, risk: .safe)
        let gone = VMFixtures.item(name: "Gone", category: .logs, size: 900, risk: .safe)
        let source = VMFixtures.scanResult(items: [kept, gone])
        let outcome = ResultsViewModel.reconciling(source) { $0.path.hasSuffix("Kept") }

        XCTAssertEqual(outcome.droppedCount, 1)
        XCTAssertEqual(outcome.result.items.map(\.name), ["Kept"])
        XCTAssertEqual(outcome.result.id, source.id, "reconciliation keeps the scan's identity")
    }

    func testReconciliationWithEverythingPresentIsIdentity() {
        let kept = VMFixtures.item(name: "Kept", category: .logs, size: 100, risk: .safe)
        let result = VMFixtures.scanResult(items: [kept])
        let outcome = ResultsViewModel.reconciling(result, fileExists: { _ in true })

        XCTAssertEqual(outcome.droppedCount, 0)
        XCTAssertEqual(outcome.result, result, "nothing dropped returns the result untouched")
    }

    /// The convenience entry point ResultsView uses: real files on disk, one
    /// of them already gone (removed by the cancelled run).
    func testReconcilingInitDropsGoneFilesAndReportsTheCount() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanora-reconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let keptURL = folder.appendingPathComponent("kept.bin")
        try Data(repeating: 0, count: 16).write(to: keptURL)
        let kept = CleanupItem(
            name: "Kept", category: .logs, path: keptURL, size: 16,
            riskLevel: .safe, reason: "test", deletionMethod: .trashDirectory
        )
        let gone = CleanupItem(
            name: "Gone", category: .logs, path: folder.appendingPathComponent("gone.bin"),
            size: 32, riskLevel: .safe, reason: "test", deletionMethod: .trashDirectory
        )

        let viewModel = ResultsViewModel(reconciling: VMFixtures.scanResult(items: [kept, gone]))
        XCTAssertEqual(viewModel.droppedInCancelledRunCount, 1)
        XCTAssertEqual(viewModel.sections[0].items.map(\.name), ["Kept"])
    }

    func testCancelledRunBannerCopy() {
        XCTAssertNil(ResultsViewModel.cancelledRunBanner(droppedCount: 0))
        XCTAssertEqual(
            ResultsViewModel.cancelledRunBanner(droppedCount: 1),
            "1 item was already cleaned in the cancelled run."
        )
        XCTAssertEqual(
            ResultsViewModel.cancelledRunBanner(droppedCount: 3),
            "3 items were already cleaned in the cancelled run."
        )
    }

    // MARK: Large-file rows (P-09)

    func testLargeFileModifiedDatesAreProbedAtInitOnlyForLargeFiles() {
        let large = VMFixtures.item(name: "Big", category: .largeFiles, size: 900, risk: .review)
        let cache = VMFixtures.item(name: "Cache", category: .applicationCaches, size: 100, risk: .safe)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let viewModel = ResultsViewModel(result: VMFixtures.scanResult(items: [large, cache])) { url in
            url.path.hasSuffix("Big") ? stamp : nil
        }

        XCTAssertEqual(viewModel.largeFileModifiedDates[large.id], stamp)
        XCTAssertNil(viewModel.largeFileModifiedDates[cache.id], "only large-file rows are statted")
    }

    func testLargeFileModifiedLineFormatsAndHidesWhenUnknown() {
        let stamp = VMFixtures.gregorianGMT.date(
            from: DateComponents(year: 2026, month: 9, day: 1, hour: 9)
        )!
        let line = ResultsViewModel.largeFileModifiedLine(
            for: stamp,
            locale: VMFixtures.posixLocale,
            timeZone: TimeZone(identifier: "GMT")!
        )
        XCTAssertEqual(line, "Modified Sep 1, 2026")
        XCTAssertNil(ResultsViewModel.largeFileModifiedLine(for: nil))
    }

    func testCleaningSelectionProvidingExposesSourceScanID() {
        let viewModel = ResultsViewModel(result: VMFixtures.scanResult(items: []))
        let provider: any CleaningSelectionProviding = viewModel
        XCTAssertEqual(provider.sourceScanID, viewModel.result.id)
    }
}
