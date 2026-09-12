import Foundation

/// One supported browser's cache layout, relative to `~/Library/Caches`.
public struct BrowserCatalog: Sendable, Equatable {
    public enum CacheLayout: Sendable, Equatable {
        /// `<base>/<Profile>/{Cache, Code Cache, GPUCache, Service Worker}`.
        case chromium
        /// `<base>/Profiles/<profile>/{cache2, startupCache, shader-cache}`.
        case firefox
        /// The whole base directory is one item (Safari).
        case wholeDirectory
    }

    public let name: String
    public let bundleID: String
    /// Path components of the browser's cache base, relative to `env.caches`.
    public let baseComponents: [String]
    public let layout: CacheLayout
    public let riskLevel: RiskLevel
    public let reason: String

    public init(
        name: String,
        bundleID: String,
        baseComponents: [String],
        layout: CacheLayout,
        riskLevel: RiskLevel,
        reason: String
    ) {
        self.name = name
        self.bundleID = bundleID
        self.baseComponents = baseComponents
        self.layout = layout
        self.riskLevel = riskLevel
        self.reason = reason
    }

    /// Chromium per-profile cache directories. The profile directory itself
    /// must survive a cleanup, so items always point at these subdirectories.
    public static let chromiumCacheDirectories = [
        "Cache", "Code Cache", "GPUCache", "Service Worker",
    ]

    public static let firefoxCacheDirectories = [
        "cache2", "startupCache", "shader-cache",
    ]

    /// Every browser in scan order. Safari sits last: it is the only
    /// `.review` entry and the one most likely to be TCC-protected.
    public static let all: [BrowserCatalog] = [
        BrowserCatalog(
            name: "Chrome",
            bundleID: "com.google.Chrome",
            baseComponents: ["Google", "Chrome"],
            layout: .chromium,
            riskLevel: .safe,
            reason: "Chrome rebuilds its cache automatically; sites may just load slightly slower on first revisit."
        ),
        BrowserCatalog(
            name: "Edge",
            bundleID: "com.microsoft.edgemac",
            baseComponents: ["Microsoft Edge"],
            layout: .chromium,
            riskLevel: .safe,
            reason: "Edge rebuilds its cache automatically; sites may just load slightly slower on first revisit."
        ),
        BrowserCatalog(
            name: "Brave",
            bundleID: "com.brave.Browser",
            baseComponents: ["BraveSoftware", "Brave-Browser"],
            layout: .chromium,
            riskLevel: .safe,
            reason: "Brave rebuilds its cache automatically; sites may just load slightly slower on first revisit."
        ),
        BrowserCatalog(
            name: "Arc",
            bundleID: "company.thebrowser.Browser",
            baseComponents: ["Arc"],
            layout: .chromium,
            riskLevel: .safe,
            reason: "Arc rebuilds its cache automatically; sites may just load slightly slower on first revisit."
        ),
        BrowserCatalog(
            name: "Opera",
            bundleID: "com.operasoftware.Opera",
            baseComponents: ["com.operasoftware.Opera"],
            layout: .chromium,
            riskLevel: .safe,
            reason: "Opera rebuilds its cache automatically; sites may just load slightly slower on first revisit."
        ),
        BrowserCatalog(
            name: "Firefox",
            bundleID: "org.mozilla.firefox",
            baseComponents: ["Firefox"],
            layout: .firefox,
            riskLevel: .safe,
            reason: "Firefox rebuilds its cache automatically; sites may just load slightly slower on first revisit."
        ),
        BrowserCatalog(
            name: "Safari",
            bundleID: "com.apple.Safari",
            baseComponents: ["com.apple.Safari"],
            layout: .wholeDirectory,
            riskLevel: .review,
            reason: "Safari's cache is sandboxed and can hold website login state. Clearing it may sign you out of some sites, so review before cleaning."
        ),
    ]

    static let safari = all.first { $0.name == "Safari" }!
}
