import Foundation

public struct ItemOutcome: Equatable, Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case removed
        case partial
        case failed
        case skipped
    }

    public var id: UUID { itemID }
    public let itemID: UUID
    public let name: String
    public let category: ScanCategory
    public let path: String
    public let status: Status
    /// Measured, not estimated: before − after re-stat.
    public let bytesFreed: Int64
    public let message: String?

    public init(
        itemID: UUID,
        name: String,
        category: ScanCategory,
        path: String,
        status: Status,
        bytesFreed: Int64,
        message: String? = nil
    ) {
        self.itemID = itemID
        self.name = name
        self.category = category
        self.path = path
        self.status = status
        self.bytesFreed = bytesFreed
        self.message = message
    }
}

public struct CleanupReport: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let outcomes: [ItemOutcome]
    public let freeSpaceBefore: Int64?
    public let freeSpaceAfter: Int64?
    public let scanResultID: UUID?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date,
        outcomes: [ItemOutcome],
        freeSpaceBefore: Int64?,
        freeSpaceAfter: Int64?,
        scanResultID: UUID?
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcomes = outcomes
        self.freeSpaceBefore = freeSpaceBefore
        self.freeSpaceAfter = freeSpaceAfter
        self.scanResultID = scanResultID
    }

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
    public var itemsRemoved: Int { outcomes.filter { $0.status == .removed }.count }
    public var partiallyRemoved: Int { outcomes.filter { $0.status == .partial }.count }
    public var failureCount: Int { outcomes.filter { $0.status == .failed }.count }
    public var bytesFreed: Int64 { outcomes.reduce(0) { $0 + $1.bytesFreed } }

    public var freedBytesInCategories: [ScanCategory: Int64] {
        Dictionary(grouping: outcomes, by: \.category)
            .mapValues { $0.reduce(0) { $0 + $1.bytesFreed } }
    }

    public func freedBytes(in category: ScanCategory) -> Int64 {
        outcomes.filter { $0.category == category }.reduce(0) { $0 + $1.bytesFreed }
    }
}
