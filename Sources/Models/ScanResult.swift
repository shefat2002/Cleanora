import Foundation

public struct CategorySummary: Equatable, Codable, Sendable, Identifiable {
    public var id: String { category.rawValue }
    public let category: ScanCategory
    public let totalBytes: Int64
    public let itemCount: Int
    public let preselectedBytes: Int64
    public let reviewBytes: Int64

    public init(
        category: ScanCategory,
        totalBytes: Int64,
        itemCount: Int,
        preselectedBytes: Int64,
        reviewBytes: Int64
    ) {
        self.category = category
        self.totalBytes = totalBytes
        self.itemCount = itemCount
        self.preselectedBytes = preselectedBytes
        self.reviewBytes = reviewBytes
    }
}

public struct ScanResult: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let items: [CleanupItem]
    public let summaries: [CategorySummary]
    public let freeSpaceBefore: Int64?
    public let scannerKeys: [ScannerKey]

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date,
        items: [CleanupItem],
        summaries: [CategorySummary] = [],
        freeSpaceBefore: Int64? = nil,
        scannerKeys: [ScannerKey] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.items = items
        self.summaries = summaries
        self.freeSpaceBefore = freeSpaceBefore
        self.scannerKeys = scannerKeys
    }

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
    public var totalBytes: Int64 {
        summaries.reduce(0) { $0 + $1.totalBytes }
    }
    public var selectedItems: [CleanupItem] { items.filter(\.selected) }
    public var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    public func items(in category: ScanCategory) -> [CleanupItem] {
        items.filter { $0.category == category }
    }

    public func summary(for category: ScanCategory) -> CategorySummary? {
        summaries.first { $0.category == category }
    }
}
