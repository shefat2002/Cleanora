import Foundation

public struct DiskOverview: Equatable, Codable, Sendable {
    public let totalCapacity: Int64
    /// Purgeable-aware figure — matches what Finder shows.
    public let availableForImportantUsage: Int64
    public let availableForPurgeable: Int64?

    public init(
        totalCapacity: Int64,
        availableForImportantUsage: Int64,
        availableForPurgeable: Int64? = nil
    ) {
        self.totalCapacity = totalCapacity
        self.availableForImportantUsage = availableForImportantUsage
        self.availableForPurgeable = availableForPurgeable
    }

    public var usedBytes: Int64 {
        max(0, totalCapacity - availableForImportantUsage)
    }
}
