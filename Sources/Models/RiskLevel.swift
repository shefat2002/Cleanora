import Foundation

/// Never introduce a fourth case without updating SafetyPolicy and the
/// Results UI badge. `.never` items must never be constructed downstream —
/// CleanupItem's init has a guard.
public enum RiskLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case safe      // auto-selected; regenerable cache/temp/log/trash-class data
    case review    // shown, never pre-selected; requires explicit opt-in
    case never     // must never reach CleanupItem; SafetyPolicy hard-rejects

    public var displayName: String {
        switch self {
        case .safe: return "Safe to remove"
        case .review: return "Review needed"
        case .never: return "Don't touch"
        }
    }

    public var symbolName: String {
        switch self {
        case .safe: return "checkmark.circle.fill"
        case .review: return "exclamationmark.triangle.fill"
        case .never: return "hand.raised.fill"
        }
    }

    public var isPreselected: Bool { self == .safe }

    public var sortOrder: Int {
        switch self {
        case .safe: return 0
        case .review: return 1
        case .never: return 2
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}
