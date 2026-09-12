import Foundation
import Observation

/// Process-wide dependency container. Views and view models receive their
/// engine objects from here; nothing constructs engines on its own.
@MainActor
@Observable
final class AppEnvironment {
    let preferences: PreferencesStore

    init(preferences: PreferencesStore = PreferencesStore()) {
        self.preferences = preferences
    }
}
