import Foundation

/// Typed mirror of user preferences, persisted in UserDefaults.
/// Defaults follow the spec's Settings section.
struct Preferences: Equatable, Codable, Sendable {
    // General
    var launchAtLogin: Bool = false
    var showCleanupReminder: Bool = false
    var confirmBeforeCleaning: Bool = true
    /// M-01: keeps the menu bar item alive when the main window closes.
    var menuBarEnabled: Bool = false

    // Scan
    var enabledCategories: Set<ScanCategory> = Set(ScanCategory.phaseOne)
    var includeDeveloperData: Bool = false

    // Cleaning
    var askBeforeDeleting: Bool = true
    var automaticallyCleanSafeItems: Bool = false
    var keepCleanupHistory: Bool = true

    // Scheduled cleanup (M-02). A scheduled run may only ever clean the
    // preselected (`.safe`) non-destructive set — scheduleAutoCleanSafeOnly
    // cannot widen that; it only decides whether the clean runs unattended
    // at all or the scheduled scan just records "scan finished".
    var scheduleEnabled: Bool = false
    var scheduleIntervalDays: Int = 7
    var scheduleAutoCleanSafeOnly: Bool = true
    /// The last schedule slot that FIRED (set at fire time, before the scan
    /// runs, so a crash mid-run cannot turn the next launch into a burst of
    /// catch-ups). Drives the next fire: lastScheduledRun + interval.
    var lastScheduledRun: Date?

    /// Accepted interval range, in days. Stored values are clamped here on
    /// use — never rewritten — so a hand-edited or future blob can't break
    /// scheduling.
    static let scheduleIntervalDaysRange = 1...30
    static let secondsPerDay: TimeInterval = 86_400

    var clampedScheduleIntervalDays: Int {
        min(
            max(scheduleIntervalDays, Self.scheduleIntervalDaysRange.lowerBound),
            Self.scheduleIntervalDaysRange.upperBound
        )
    }

    var scheduleInterval: TimeInterval {
        TimeInterval(clampedScheduleIntervalDays) * Self.secondsPerDay
    }

    var scanOptions: ScanOptions {
        var options = ScanOptions()
        options.enabledCategories = enabledCategories
        options.includeDeveloperData = includeDeveloperData
        return options
    }

    /// Keeps the default-values construction (`Preferences()`) available —
    /// the custom `init(from:)` below suppresses the synthesized memberwise
    /// initializer.
    init() {}

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, showCleanupReminder, confirmBeforeCleaning, menuBarEnabled
        case enabledCategories, includeDeveloperData
        case askBeforeDeleting, automaticallyCleanSafeItems, keepCleanupHistory
        case scheduleEnabled, scheduleIntervalDays, scheduleAutoCleanSafeOnly
        case lastScheduledRun
    }

    /// Tolerant decode: every field falls back to its default when the key
    /// is absent. Synthesized decoding would throw `keyNotFound` for any new
    /// field missing from an older build's blob — landing in the corrupt-blob
    /// reset path and silently wiping the user's settings on upgrade.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        showCleanupReminder = try container.decodeIfPresent(Bool.self, forKey: .showCleanupReminder) ?? false
        confirmBeforeCleaning = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeCleaning) ?? true
        menuBarEnabled = try container.decodeIfPresent(Bool.self, forKey: .menuBarEnabled) ?? false
        enabledCategories = try container.decodeIfPresent(
            Set<ScanCategory>.self, forKey: .enabledCategories
        ) ?? Set(ScanCategory.phaseOne)
        includeDeveloperData = try container.decodeIfPresent(Bool.self, forKey: .includeDeveloperData) ?? false
        askBeforeDeleting = try container.decodeIfPresent(Bool.self, forKey: .askBeforeDeleting) ?? true
        automaticallyCleanSafeItems = try container.decodeIfPresent(
            Bool.self, forKey: .automaticallyCleanSafeItems
        ) ?? false
        keepCleanupHistory = try container.decodeIfPresent(Bool.self, forKey: .keepCleanupHistory) ?? true
        scheduleEnabled = try container.decodeIfPresent(Bool.self, forKey: .scheduleEnabled) ?? false
        scheduleIntervalDays = try container.decodeIfPresent(Int.self, forKey: .scheduleIntervalDays) ?? 7
        scheduleAutoCleanSafeOnly = try container.decodeIfPresent(
            Bool.self, forKey: .scheduleAutoCleanSafeOnly
        ) ?? true
        lastScheduledRun = try container.decodeIfPresent(Date.self, forKey: .lastScheduledRun)
    }
}

/// Observable facade over UserDefaults. Views bind to `preferences`;
/// every mutation is persisted immediately.
@MainActor
@Observable
final class PreferencesStore {
    private let defaults: UserDefaults
    private static let key = "com.cleanora.preferences.v1"

    /// Writable (not private(set)) so @Bindable bindings through nested key
    /// paths work — a binding mutation reassigns the whole struct, firing didSet.
    var preferences: Preferences {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferences = Self.load(from: defaults) ?? Preferences()
    }

    var value: Preferences { preferences }

    func update(_ transform: (inout Preferences) -> Void) {
        var copy = preferences
        transform(&copy)
        preferences = copy
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private static func load(from defaults: UserDefaults) -> Preferences? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        do {
            return try JSONDecoder().decode(Preferences.self, from: data)
        } catch {
            // Corrupt or incompatible blob: drop it so the next persist
            // writes fresh defaults instead of keeping a dead value around.
            defaults.removeObject(forKey: Self.key)
            return nil
        }
    }
}
