import SwiftUI

/// Dashboard "Suggestions" card (M-03): informational recommendations from
/// the last scan. Rows never select anything — "Review" routes to Results
/// with the recommendation's category highlighted.
struct SuggestionsCardView: View {
    let recommendations: [Recommendation]
    let onReview: (Recommendation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.spacingS) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Suggestions")
                    .font(.headline)
                Spacer(minLength: Design.spacingS)
                Text("Based on your last scan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Design.spacingM)
            .accessibilityElement(children: .combine)

            Divider()

            VStack(spacing: 0) {
                ForEach(recommendations) { recommendation in
                    row(recommendation)
                    Divider()
                        .opacity(0.5)
                        .padding(.leading, Design.spacingM)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: Design.cornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.cornerRadius)
                .strokeBorder(.quaternary)
        )
        .accessibilityElement(children: .contain)
    }

    private func row(_ recommendation: Recommendation) -> some View {
        HStack(alignment: .top, spacing: Design.spacingM) {
            CategoryIcon(category: recommendation.category, size: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(recommendation.title)
                    .font(.body.weight(.medium))
                Text(recommendation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: Design.spacingS)

            VStack(alignment: .trailing, spacing: Design.spacingXS) {
                Text(recommendation.estimatedBytes.formattedByteCount)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
                Button("Review") {
                    onReview(recommendation)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Review \(recommendation.title)")
                .accessibilityHint(
                    "Opens the results and highlights \(recommendation.category.displayName). Nothing is selected."
                )
            }
        }
        .padding(.horizontal, Design.spacingM)
        .padding(.vertical, Design.spacingS)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SuggestionsViewModel.rowAccessibilityLabel(for: recommendation))
    }
}
