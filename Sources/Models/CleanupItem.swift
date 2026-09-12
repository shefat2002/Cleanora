import Foundation

/// The single currency type between scan engine, cleanup engine and UI.
/// Value type, Sendable, Codable — but `selected` is deliberately NOT
/// persisted: selection is UI-transient state, never written to disk.
public struct CleanupItem: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let name: String
    /// Sub-row grouping label in Results ("Chrome", "Xcode"); nil for
    /// categories without app grouping.
    public let appName: String?
    public let category: ScanCategory
    public let path: URL
    /// Allocated bytes (APFS-accurate, matches what freeing returns);
    /// logical size only where allocation data is unavailable.
    public let size: Int64
    public let fileCount: Int?
    public let riskLevel: RiskLevel
    public var selected: Bool
    public let reason: String
    public let deletionMethod: DeletionMethod
    /// Extra confirmation class. `.standard` everywhere except Trash emptying.
    public let confirmationLevel: ConfirmationLevel

    public enum ConfirmationLevel: String, Codable, Sendable {
        case standard
        case destructive
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, appName, category, path, size, fileCount
        case riskLevel, selected, reason, deletionMethod, confirmationLevel
    }

    /// Encodes everything EXCEPT `selected` — selection is UI-transient.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(appName, forKey: .appName)
        try container.encode(category, forKey: .category)
        try container.encode(path, forKey: .path)
        try container.encode(size, forKey: .size)
        try container.encodeIfPresent(fileCount, forKey: .fileCount)
        try container.encode(riskLevel, forKey: .riskLevel)
        try container.encode(reason, forKey: .reason)
        try container.encode(deletionMethod, forKey: .deletionMethod)
        try container.encode(confirmationLevel, forKey: .confirmationLevel)
    }

    public init(
        id: UUID = UUID(),
        name: String,
        appName: String? = nil,
        category: ScanCategory,
        path: URL,
        size: Int64,
        fileCount: Int? = nil,
        riskLevel: RiskLevel,
        selected: Bool? = nil,
        reason: String,
        deletionMethod: DeletionMethod,
        confirmationLevel: ConfirmationLevel = .standard
    ) {
        // Fail fast at the boundary: a `.never` item must never exist, so it
        // can never be displayed, selected, or deleted.
        precondition(
            riskLevel != .never,
            "CleanupItem must never be created with riskLevel .never: \(path.path)"
        )
        self.id = id
        self.name = name
        self.appName = appName
        self.category = category
        self.path = path
        self.size = size
        self.fileCount = fileCount
        self.riskLevel = riskLevel
        self.selected = selected ?? riskLevel.isPreselected
        self.reason = reason
        self.deletionMethod = deletionMethod
        self.confirmationLevel = confirmationLevel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        category = try container.decode(ScanCategory.self, forKey: .category)
        path = try container.decode(URL.self, forKey: .path)
        size = try container.decode(Int64.self, forKey: .size)
        fileCount = try container.decodeIfPresent(Int.self, forKey: .fileCount)
        riskLevel = try container.decode(RiskLevel.self, forKey: .riskLevel)
        // I1 on the Codable path too: a crafted/persisted `.never` must not
        // round-trip into display or selection state.
        guard riskLevel != .never else {
            throw DecodingError.dataCorruptedError(
                forKey: .riskLevel, in: container,
                debugDescription: "CleanupItem must never be created with riskLevel .never"
            )
        }
        selected = try container.decodeIfPresent(Bool.self, forKey: .selected)
            ?? riskLevel.isPreselected
        reason = try container.decode(String.self, forKey: .reason)
        deletionMethod = try container.decode(DeletionMethod.self, forKey: .deletionMethod)
        confirmationLevel = try container.decode(
            ConfirmationLevel.self, forKey: .confirmationLevel
        )
    }

    public func withSelection(_ isSelected: Bool) -> CleanupItem {
        var copy = self
        copy.selected = isSelected
        return copy
    }
}
