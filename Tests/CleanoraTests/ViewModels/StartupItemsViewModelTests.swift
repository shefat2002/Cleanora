import XCTest
@testable import Cleanora

@MainActor
final class StartupItemsViewModelTests: XCTestCase {
    func testRowsMapStatusLinesAndToggleAvailability() throws {
        let rows = StartupItemsViewModel.rows(for: [
            StartupItem(
                identifier: "com.cleanora.app",
                displayName: "Cleanora",
                kindLabel: "Login item",
                isManagedByCleanora: true,
                isEnabled: true
            ),
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(try XCTUnwrap(rows.first).isToggleEnabled)
        XCTAssertEqual(try XCTUnwrap(rows.first).statusLine, "On")
    }

    func testForeignItemsAreNeverTogglable() {
        let rows = StartupItemsViewModel.rows(for: [
            StartupItem(
                identifier: "com.other.helper",
                displayName: "Other Helper",
                kindLabel: "Login item",
                isManagedByCleanora: false,
                isEnabled: true
            ),
            StartupItem(
                identifier: "com.other.helper2",
                displayName: "Other Helper 2",
                kindLabel: "Login item",
                isManagedByCleanora: false,
                isEnabled: false
            ),
        ])
        XCTAssertTrue(rows.allSatisfy { !$0.isToggleEnabled }, "only Cleanora's own items are manageable")
        XCTAssertEqual(rows.map(\.statusLine), [
            "On — managed in System Settings",
            "Managed in System Settings",
        ])
    }

    func testRefreshLoadsFromController() {
        let viewModel = StartupItemsViewModel(
            controller: StartupItemsController(
                list: {
                    [
                        StartupItem(
                            identifier: "com.cleanora.app",
                            displayName: "Cleanora",
                            kindLabel: "Login item",
                            isManagedByCleanora: true,
                            isEnabled: false
                        )
                    ]
                },
                setEnabled: { _, _ in .succeeded },
                openSystemSettings: {}
            )
        )
        viewModel.refresh()
        XCTAssertTrue(viewModel.didLoad)
        XCTAssertEqual(viewModel.rows.count, 1)
        XCTAssertEqual(viewModel.rows.first?.statusLine, "Off")
    }

    func testForeignItemsHintDirectsToSystemSettings() {
        XCTAssertTrue(StartupItemsViewModel.foreignItemsHint.contains("System Settings"))
    }
}
