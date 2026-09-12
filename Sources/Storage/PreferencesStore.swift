import Foundation

/// Typed mirror of user preferences, persisted in UserDefaults.
/// Defaults follow the spec's Settings section.
struct Preferences: Equatable, Codable, Sendable {
    // General
    var launchAtLogin: Bool = false
    var showCleanupReminder: Bool = false
    var confirmBeforeCleaning: Bool = true

    // Scan
    var enabledCategories: Set<ScanCategory> = Set(ScanCategory.phaseOne)
    var includeDeveloperData: Bool = false

    // Cleaning
    var askBeforeDeleting: Bool = true
    var automaticallyCleanSafeItems: Bool = false
    var keepCleanupHistory: Bool = true

    var scanOptions: ScanOptions {
        var options = ScanOptions()
        options.enabledCategories = enabledCategories
        options.includeDeveloperData = includeDeveloperData
        return options
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
        return try? JSONDecoder().decode(Preferences.self, from: data)
    }
}
