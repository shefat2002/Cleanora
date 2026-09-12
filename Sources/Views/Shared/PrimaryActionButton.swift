import SwiftUI

/// The app's single prominent action style (Scan Mac, Clean Now, Done).
/// Large, accent-filled, centered on screen.
struct PrimaryActionButton: View {
    let title: String
    var systemImage: String?
    /// VoiceOver hint; keep it factual — what happens next, no scare copy.
    var hint: String?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.spacingS) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            .padding(.horizontal, Design.spacingL)
            .padding(.vertical, Design.spacingS)
            .frame(minWidth: 180)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .modifier(ConditionalHint(hint: hint))
    }
}

/// Applies .accessibilityHint only when copy exists — an empty hint still
/// round-trips through VoiceOver as a pause.
private struct ConditionalHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint, !hint.isEmpty {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}
