import Foundation

/// One per-bundle deviation from the default "app caches are safe to trash"
/// rule. Extending this list needs strong evidence the cache is NOT blindly
/// regenerable — `.review` items are never preselected and cost the user a
/// decision.
public struct AppCacheOverride: Sendable, Equatable {
    public let bundleID: String
    public let appName: String
    public let riskLevel: RiskLevel
    public let reason: String

    public init(bundleID: String, appName: String, riskLevel: RiskLevel, reason: String) {
        self.bundleID = bundleID
        self.appName = appName
        self.riskLevel = riskLevel
        self.reason = reason
    }
}

/// The ship-set of application-cache risk overrides (task C-02).
public enum AppCacheOverrides: Sendable {
    public static let standard: [AppCacheOverride] = [
        AppCacheOverride(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            riskLevel: .review,
            reason: "Safari's cache lives inside its sandbox. Clearing it can sign you out of websites, so review it before cleaning."
        ),
        AppCacheOverride(
            bundleID: "com.docker.docker",
            appName: "Docker",
            riskLevel: .review,
            reason: "Docker rebuilds this cache on demand, but the next build can be much slower without it."
        ),
    ]

    public static func matching(bundleID: String) -> AppCacheOverride? {
        standard.first { $0.bundleID == bundleID }
    }
}
