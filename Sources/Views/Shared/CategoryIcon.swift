import SwiftUI

/// SF Symbol in a soft accent-tinted rounded square — the app's only icon
/// treatment. Decorative: hidden from VoiceOver, the row label carries
/// meaning.
struct CategoryIcon: View {
    let category: ScanCategory
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: category.symbolName)
            .font(.system(size: size * 0.52, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(
                Color.accentColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: size * 0.28)
            )
            .accessibilityHidden(true)
    }
}
