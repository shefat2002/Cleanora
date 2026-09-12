import Foundation

public struct CleanupHistoryEntry: Identifiable, Equatable, Codable, Sendable {
    public static let schemaVersion: Int = 1

    public let schemaVersion: Int
    public let id: UUID
    public let date: Date
    public let bytesFreed: Int64
    public let itemsRemoved: Int
    public let duration: TimeInterval
    public let categoryTotals: [CategoryTotal]
    public let appVersion: String

    public struct CategoryTotal: Codable, Hashable, Sendable {
        public let category: ScanCategory
        public let bytes: Int64

        public init(category: ScanCategory, bytes: Int64) {
            self.category = category
            self.bytes = bytes
        }
    }

    public init(
        schemaVersion: Int = CleanupHistoryEntry.schemaVersion,
        id: UUID,
        date: Date,
        bytesFreed: Int64,
        itemsRemoved: Int,
        duration: TimeInterval,
        categoryTotals: [CategoryTotal],
        appVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.date = date
        self.bytesFreed = bytesFreed
        self.itemsRemoved = itemsRemoved
        self.duration = duration
        self.categoryTotals = categoryTotals
        self.appVersion = appVersion
    }

    public init(from report: CleanupReport, appVersion: String) {
        self.init(
            id: report.id,
            date: report.finishedAt,
            bytesFreed: report.bytesFreed,
            itemsRemoved: report.itemsRemoved + report.partiallyRemoved,
            duration: report.duration,
            categoryTotals: report.freedBytesInCategories
                .filter { $0.value > 0 }
                .map { CategoryTotal(category: $0.key, bytes: $0.value) }
                .sorted { $0.category.sortOrder < $1.category.sortOrder },
            appVersion: appVersion
        )
    }
}
