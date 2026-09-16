import XCTest
@testable import Cleanora

/// PreferencesStore (M-02 scheduled-cleanup fields): persistence round-trip,
/// interval clamping, and backward compatibility — a pre-schedule blob (old
/// build) must decode with the new fields defaulted, never rejected as
/// corrupt (a corrupt blob would silently reset the user's whole settings).
@MainActor
final class PreferencesStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "PreferencesStoreTests-\(UUID().uuidString)")!
    }

    private var preferencesKey: String { "com.cleanora.preferences.v1" }

    // MARK: - Round-trip

    func testScheduleFieldsRoundTripThroughPersistence() {
        let defaults = makeDefaults()
        let store = PreferencesStore(defaults: defaults)
        let runDate = Date(timeIntervalSinceReferenceDate: 800_000_000)

        store.update {
            $0.scheduleEnabled = true
            $0.scheduleIntervalDays = 14
            $0.scheduleAutoCleanSafeOnly = false
            $0.lastScheduledRun = runDate
        }

        let reloaded = PreferencesStore(defaults: defaults)
        XCTAssertTrue(reloaded.value.scheduleEnabled)
        XCTAssertEqual(reloaded.value.scheduleIntervalDays, 14)
        XCTAssertFalse(reloaded.value.scheduleAutoCleanSafeOnly)
        XCTAssertEqual(reloaded.value.lastScheduledRun, runDate)
    }

    func testScheduleDefaultsMatchSpec() {
        let preferences = Preferences()
        XCTAssertFalse(preferences.scheduleEnabled, "scheduling is opt-in")
        XCTAssertEqual(preferences.scheduleIntervalDays, 7)
        XCTAssertTrue(preferences.scheduleAutoCleanSafeOnly)
        XCTAssertNil(preferences.lastScheduledRun)
    }

    // MARK: - Interval clamping (1...30 on use)

    func testScheduleIntervalDaysClampedToOneThroughThirty() {
        var preferences = Preferences()
        preferences.scheduleIntervalDays = 0
        XCTAssertEqual(preferences.clampedScheduleIntervalDays, 1)
        preferences.scheduleIntervalDays = -5
        XCTAssertEqual(preferences.clampedScheduleIntervalDays, 1)
        preferences.scheduleIntervalDays = 7
        XCTAssertEqual(preferences.clampedScheduleIntervalDays, 7)
        preferences.scheduleIntervalDays = 30
        XCTAssertEqual(preferences.clampedScheduleIntervalDays, 30)
        preferences.scheduleIntervalDays = 31
        XCTAssertEqual(preferences.clampedScheduleIntervalDays, 30)
    }

    func testScheduleIntervalIsClampedDaysInSeconds() {
        var preferences = Preferences()
        preferences.scheduleIntervalDays = 99
        XCTAssertEqual(preferences.scheduleInterval, 30 * 86_400, accuracy: 0.001)
        preferences.scheduleIntervalDays = 0
        XCTAssertEqual(preferences.scheduleInterval, 86_400, accuracy: 0.001)
    }

    // MARK: - Backward compatibility

    // A persisted blob from a build without the schedule fields must load
    // with the new fields at their defaults and the legacy values intact —
    // not fall into the corrupt-blob reset path.
    func testLegacyBlobWithoutScheduleFieldsDecodesWithScheduleDefaults() throws {
        let defaults = makeDefaults()
        let legacy = """
        {"launchAtLogin": true, "askBeforeDeleting": false, \
        "enabledCategories": ["applicationCaches", "logs"], "keepCleanupHistory": false}
        """
        defaults.set(Data(legacy.utf8), forKey: preferencesKey)

        let store = PreferencesStore(defaults: defaults)

        XCTAssertTrue(store.value.launchAtLogin)
        XCTAssertFalse(store.value.askBeforeDeleting)
        XCTAssertFalse(store.value.keepCleanupHistory)
        XCTAssertEqual(store.value.enabledCategories, [.applicationCaches, .logs])
        XCTAssertFalse(store.value.scheduleEnabled)
        XCTAssertEqual(store.value.clampedScheduleIntervalDays, 7)
        XCTAssertTrue(store.value.scheduleAutoCleanSafeOnly)
        XCTAssertNil(store.value.lastScheduledRun)
    }

    // The next mutation (any `update`) must write the full current shape
    // (schedule fields present) so later loads never see the legacy shape
    // again. Constructing a store alone does not persist — only a write does.
    func testLegacyBlobConvergesToCurrentShapeOnNextPersist() throws {
        let defaults = makeDefaults()
        let legacy = Data("{\"askBeforeDeleting\": false}".utf8)
        defaults.set(legacy, forKey: preferencesKey)

        let store = PreferencesStore(defaults: defaults)
        XCTAssertFalse(store.value.scheduleEnabled, "legacy blob: schedule defaulted off")
        XCTAssertTrue(store.value.askBeforeDeleting == false, "legacy value preserved")

        let runDate = Date(timeIntervalSinceReferenceDate: 900_000_000)
        store.update {
            $0.scheduleEnabled = true
            $0.lastScheduledRun = runDate
        }

        let raw = try XCTUnwrap(defaults.data(forKey: preferencesKey))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        )
        XCTAssertEqual(object["scheduleEnabled"] as? Bool, true)
        XCTAssertNotNil(object["scheduleIntervalDays"])
        XCTAssertNotNil(object["scheduleAutoCleanSafeOnly"])
        XCTAssertNotNil(object["lastScheduledRun"])

        // The converged file loads back with every field intact.
        let reloaded = PreferencesStore(defaults: defaults)
        XCTAssertTrue(reloaded.value.scheduleEnabled)
        XCTAssertTrue(reloaded.value.askBeforeDeleting == false)
        XCTAssertEqual(reloaded.value.lastScheduledRun, runDate)
    }

    // A blob from a build that still carried the removed `showCleanupReminder`
    // key must decode with every other field intact — `JSONDecoder` ignores
    // unknown keys, so dropping the field from `Preferences` never lands an
    // old blob in the corrupt-blob reset path (which would wipe settings).
    func testLegacyBlobWithCleanupReminderKeyStillDecodes() throws {
        let defaults = makeDefaults()
        let legacy = """
        {"launchAtLogin": true, "showCleanupReminder": true, \
        "askBeforeDeleting": false, "keepCleanupHistory": false, \
        "enabledCategories": ["applicationCaches", "logs"]}
        """
        defaults.set(Data(legacy.utf8), forKey: preferencesKey)

        let store = PreferencesStore(defaults: defaults)

        XCTAssertTrue(store.value.launchAtLogin, "legacy value preserved")
        XCTAssertFalse(store.value.askBeforeDeleting, "legacy value preserved")
        XCTAssertFalse(store.value.keepCleanupHistory, "legacy value preserved")
        XCTAssertEqual(store.value.enabledCategories, [.applicationCaches, .logs])
        XCTAssertTrue(store.value.confirmBeforeCleaning, "unset fields keep their defaults")
        XCTAssertFalse(store.value.scheduleEnabled)
    }

    // The removed preference must not reappear in freshly written blobs: after
    // any mutation the raw persisted JSON carries no `showCleanupReminder` key.
    func testPersistedBlobNoLongerContainsCleanupReminderKey() throws {
        let defaults = makeDefaults()
        let store = PreferencesStore(defaults: defaults)

        store.update { $0.launchAtLogin = true }

        let raw = try XCTUnwrap(defaults.data(forKey: preferencesKey))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        )
        XCTAssertNil(object["showCleanupReminder"], "dead key must not be persisted")
        XCTAssertEqual(object["launchAtLogin"] as? Bool, true, "real fields still persist")
    }
}
