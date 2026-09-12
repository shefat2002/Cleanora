import XCTest
@testable import Cleanora

@MainActor
final class DeveloperCleanupViewModelTests: XCTestCase {
    private func developerItem(
        name: String,
        size: Int64,
        appName: String? = nil,
        risk: RiskLevel = .safe,
        path: String = "/Users/dev/Library/Caches/example"
    ) -> CleanupItem {
        CleanupItem(
            name: name,
            appName: appName,
            category: .developerData,
            path: URL(fileURLWithPath: path),
            size: size,
            riskLevel: risk,
            reason: "Fixture reason for \(name)",
            deletionMethod: .trashDirectory
        )
    }

    private func result(_ items: [CleanupItem]) -> ScanResult {
        VMFixtures.scanResult(items: items)
    }

    // MARK: Selection defaults

    func testNothingIsPreselectedEvenForSafeItems() {
        let viewModel = DeveloperCleanupViewModel(result: result([
            developerItem(name: "DerivedData", size: 100, appName: "Xcode", risk: .safe),
            developerItem(name: "Cache", size: 50, appName: "Homebrew", risk: .review),
            // A crafted producer that marked a safe item selected must be
            // normalized away — VMFixtures.item carries the `selected:` knob.
            VMFixtures.item(
                name: "Crafted",
                category: .developerData,
                size: 10,
                risk: .safe,
                appName: "npm",
                selected: true
            ),
        ]))

        XCTAssertEqual(viewModel.selectedItems, [], "spec §12: developer rows never start selected")
        XCTAssertEqual(viewModel.selectedBytes, 0)
        XCTAssertFalse(viewModel.canClean)
    }

    func testNonDeveloperItemsAreIgnored() {
        let viewModel = DeveloperCleanupViewModel(result: result([
            VMFixtures.item(name: "Chrome", category: .applicationCaches, size: 900, risk: .safe),
            developerItem(name: "DerivedData", size: 100, appName: "Xcode"),
        ]))
        XCTAssertEqual(viewModel.groups.count, 1)
        XCTAssertEqual(viewModel.foundBytes, 100)
    }

    // MARK: Tool grouping (spec §12)

    func testGroupsFollowSpec12ToolFamilies() {
        let viewModel = DeveloperCleanupViewModel(result: result([
            developerItem(name: "DerivedData", size: 800, appName: "Xcode"),
            developerItem(name: "Archives", size: 700, appName: "Xcode"),
            developerItem(name: "Device Support", size: 600, appName: "Xcode"),
            developerItem(name: "Homebrew", size: 500, appName: "Homebrew"),
            developerItem(name: "npm cache", size: 400, appName: "npm"),
            developerItem(name: "Yarn cache", size: 300, appName: "Yarn"),
            developerItem(name: "pip cache", size: 200, appName: "pip"),
            developerItem(name: "Build cache", size: 100, appName: "Docker"),
        ]))

        XCTAssertEqual(viewModel.groups.map(\.name), ["Xcode", "Node", "Python", "Homebrew", "Docker"])
        let node = viewModel.groups.first { $0.name == "Node" }!
        XCTAssertEqual(node.rows.map(\.item.name), ["npm cache", "Yarn cache"], "npm and Yarn share the Node family per spec §12")
    }

    func testPathAndNameFallbacksMapIntoToolFamilies() {
        let viewModel = DeveloperCleanupViewModel(result: result([
            developerItem(
                name: "00D9-CORESIM", size: 10, path: "/Users/dev/Library/Developer/CoreSimulator/Caches"
            ),
            developerItem(name: "_cacache", size: 20, path: "/Users/dev/.npm/_cacache"),
            developerItem(name: "Docker.raw", size: 30, path: "/Users/dev/Library/Containers/com.docker.docker"),
        ]))

        XCTAssertEqual(viewModel.groups.map(\.name), ["Xcode", "Node", "Docker"])
    }

    func testUnknownToolKeepsItsOwnGroupSortedAfterKnownFamilies() {
        let viewModel = DeveloperCleanupViewModel(result: result([
            developerItem(name: "Cargo registry", size: 40, appName: "Cargo"),
            developerItem(name: "DerivedData", size: 800, appName: "Xcode"),
            developerItem(name: "Gradle", size: 30, appName: "Gradle"),
        ]))

        XCTAssertEqual(viewModel.groups.map(\.name), ["Xcode", "Cargo", "Gradle"])
    }

    func testRowsSortedBySizeWithinGroup() {
        let viewModel = DeveloperCleanupViewModel(result: result([
            developerItem(name: "Small", size: 10, appName: "Xcode"),
            developerItem(name: "Large", size: 900, appName: "Xcode"),
            developerItem(name: "Medium", size: 100, appName: "Xcode"),
        ]))

        XCTAssertEqual(viewModel.groups[0].rows.map(\.item.name), ["Large", "Medium", "Small"])
    }

    // MARK: Docker reason prominence

    func testDockerRowsLeadWithTheirReason() {
        let docker = developerItem(name: "Build cache", size: 100, appName: "Docker")
        let xcode = developerItem(name: "DerivedData", size: 100, appName: "Xcode")
        let viewModel = DeveloperCleanupViewModel(result: result([docker, xcode]))

        let dockerRow = viewModel.groups.first { $0.name == "Docker" }!.rows[0]
        let xcodeRow = viewModel.groups.first { $0.name == "Xcode" }!.rows[0]
        XCTAssertTrue(dockerRow.isReasonProminent, "Docker rows show the prune note, never a bare path")
        XCTAssertFalse(xcodeRow.isReasonProminent)
    }

    // MARK: Selection

    func testSelectionUpdatesGroupAndTotals() {
        let a = developerItem(name: "A", size: 100, appName: "Xcode")
        let b = developerItem(name: "B", size: 200, appName: "Homebrew")
        let viewModel = DeveloperCleanupViewModel(result: result([a, b]))

        let xcode = viewModel.groups.first { $0.name == "Xcode" }!
        viewModel.setSelection(true, itemID: a.id)
        XCTAssertEqual(viewModel.selectedBytes, 100)
        XCTAssertEqual(viewModel.selectedCount, 1)
        XCTAssertEqual(
            viewModel.groups.first { $0.name == "Xcode" }!.selection,
            .all,
            "groups re-derive from the same source of truth"
        )

        let homebrew = viewModel.groups.first { $0.name == "Homebrew" }!
        viewModel.setGroupSelection(homebrew, isSelected: true)
        XCTAssertEqual(viewModel.selectedBytes, 300)
        XCTAssertTrue(viewModel.canClean)

        viewModel.setGroupSelection(homebrew, isSelected: false)
        XCTAssertEqual(viewModel.selectedBytes, 100)
        XCTAssertEqual(viewModel.groups.first { $0.name == "Homebrew" }!.selection, .none)
    }

    // MARK: Shared confirmation sheet seam

    func testConformsToCleaningSelectionProviding() {
        let a = developerItem(name: "A", size: 100, appName: "Xcode")
        let viewModel = DeveloperCleanupViewModel(result: result([a]))
        let provider: any CleaningSelectionProviding = viewModel

        viewModel.setSelection(true, itemID: a.id)
        XCTAssertEqual(provider.selectedItems.map(\.name), ["A"])
        XCTAssertEqual(provider.selectedBytes, 100)
        XCTAssertEqual(provider.selectedCount, 1)
        XCTAssertEqual(provider.sourceScanID, viewModel.sourceScanID)
        XCTAssertFalse(provider.requiresDestructiveConfirmation)
    }

    func testDestructiveSelectionIsReportedToTheSheet() {
        // A developer item flagged destructive by its producer must still
        // raise the irreversible step — the view model is the sheet's source.
        let destructive = CleanupItem(
            name: "Dev destructive", appName: "Xcode", category: .developerData,
            path: URL(fileURLWithPath: "/Users/dev/Library/Developer/Xcode/DerivedData"),
            size: 10, riskLevel: .review, reason: "fixture",
            deletionMethod: .removeContents, confirmationLevel: .destructive
        )
        let viewModel = DeveloperCleanupViewModel(result: result([destructive]))
        viewModel.setSelection(true, itemID: destructive.id)
        XCTAssertTrue(viewModel.requiresDestructiveConfirmation)

        viewModel.setSelection(false, itemID: destructive.id)
        XCTAssertFalse(viewModel.requiresDestructiveConfirmation)
    }

    // MARK: Empty state

    func testEmptyWhenScanHasNoDeveloperItems() {
        let viewModel = DeveloperCleanupViewModel(result: result([
            VMFixtures.item(name: "Chrome", category: .applicationCaches, size: 900, risk: .safe),
        ]))
        XCTAssertTrue(viewModel.isEmpty)
        XCTAssertTrue(viewModel.groups.isEmpty)
    }
}
