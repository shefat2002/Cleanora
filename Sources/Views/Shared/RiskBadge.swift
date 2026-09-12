import SwiftUI

/// Safety classification chip. Always text + symbol + color — never color
/// alone — and the accessibility label is the full risk phrase.
struct RiskBadge: View {
    let level: RiskLevel

    var body: some View {
        Label(level.badgeText, systemImage: level.symbolName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(level.badgeColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(level.badgeColor.opacity(0.12), in: Capsule())
            .accessibilityLabel(level.displayName)
    }
}
