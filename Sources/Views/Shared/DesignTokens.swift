import SwiftUI

/// Design tokens: one accent (Assets AccentColor), generous whitespace, no
/// alarm-red chrome. Keep every screen on these values.
enum Design {
    static let spacingXS: CGFloat = 6
    static let spacingS: CGFloat = 10
    static let spacingM: CGFloat = 16
    static let spacingL: CGFloat = 24
    static let spacingXL: CGFloat = 40
    static let cornerRadius: CGFloat = 10
    /// Central content column width for the main window.
    static let contentWidth: CGFloat = 620
    static let narrowColumnWidth: CGFloat = 400
}

/// Semantic colors used across screens. Defined once so a category or risk
/// never shifts meaning between the Results list and the Confirmation sheet.
extension RiskLevel {
    var badgeColor: Color {
        switch self {
        case .safe: return .green
        case .review: return .orange
        case .never: return .red
        }
    }

    /// Compact badge copy — the full phrase stays in `displayName` for
    /// accessibility so VoiceOver never reads just "Safe".
    var badgeText: String {
        switch self {
        case .safe: return "Safe"
        case .review: return "Review"
        case .never: return "Never"
        }
    }
}
