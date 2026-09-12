import Foundation

/// Per-scan configuration. Mirrored into PreferencesStore; scanners and the
/// coordinator receive it as a plain value.
public struct ScanOptions: Equatable, Codable, Sendable {
    public var enabledCategories: Set<ScanCategory>
    public var includeDeveloperData: Bool
    public var largeFileMinimumBytes: Int64
    public var largeFileLimit: Int
    /// Soft budget: a pathological tree yields partial results + `.tooLargeToScan`.
    public var perScanTimeBudget: TimeInterval

    public init(
        enabledCategories: Set<ScanCategory> = Set(ScanCategory.phaseOne),
        includeDeveloperData: Bool = false,
        largeFileMinimumBytes: Int64 = 500_000_000,
        largeFileLimit: Int = 100,
        perScanTimeBudget: TimeInterval = 120
    ) {
        self.enabledCategories = enabledCategories
        self.includeDeveloperData = includeDeveloperData
        self.largeFileMinimumBytes = largeFileMinimumBytes
        self.largeFileLimit = largeFileLimit
        self.perScanTimeBudget = perScanTimeBudget
    }
}
