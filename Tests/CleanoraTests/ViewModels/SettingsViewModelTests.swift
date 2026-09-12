import XCTest
@testable import Cleanora

final class SettingsViewModelTests: XCTestCase {
    func testTogglingCategoryOnInserts() {
        let updated = SettingsViewModel.updatedCategories(
            current: [.applicationCaches],
            toggling: .logs,
            isOn: true
        )
        XCTAssertEqual(updated, [.applicationCaches, .logs])
    }

    func testTogglingCategoryOffRemovesWhenOthersRemain() {
        let updated = SettingsViewModel.updatedCategories(
            current: Set(ScanCategory.phaseOne),
            toggling: .logs,
            isOn: false
        )
        XCTAssertFalse(updated.contains(.logs))
        XCTAssertEqual(updated.count, 4)
    }

    func testLastEnabledCategoryCannotBeRemoved() {
        let updated = SettingsViewModel.updatedCategories(
            current: [.trash],
            toggling: .trash,
            isOn: false
        )
        XCTAssertEqual(updated, [.trash], "a scan needs at least one category")
    }

    // MARK: Copy

    func testHintsAreNonEmpty() {
        XCTAssertFalse(SettingsViewModel.developerDataHint.isEmpty)
        XCTAssertFalse(SettingsViewModel.autoCleanHint.isEmpty)
        XCTAssertFalse(SettingsViewModel.confirmationHint.isEmpty)
    }

    func testLaunchAtLoginStatusDescribesSuccess() {
        XCTAssertEqual(
            SettingsViewModel.launchAtLoginStatus(outcome: .succeeded, enabled: true),
            "Cleanora opens when you log in."
        )
        XCTAssertEqual(
            SettingsViewModel.launchAtLoginStatus(outcome: .succeeded, enabled: false),
            "Cleanora no longer opens at login."
        )
    }

    func testLaunchAtLoginStatusSurfacesTheServiceManagementError() {
        let status = SettingsViewModel.launchAtLoginStatus(
            outcome: .failed("Operation not permitted"), enabled: false
        )
        XCTAssertTrue(
            status.contains("Operation not permitted"),
            "dev builds are unsigned — the SMError must be readable in the row, never swallowed"
        )
        XCTAssertTrue(status.hasPrefix("Couldn't update launch at login"))
    }
}
