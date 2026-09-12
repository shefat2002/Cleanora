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

    func testHintsAreNonEmpty() {
        XCTAssertFalse(SettingsViewModel.launchAtLoginUnavailableHint.isEmpty)
        XCTAssertFalse(SettingsViewModel.developerDataUnavailableHint.isEmpty)
    }
}
