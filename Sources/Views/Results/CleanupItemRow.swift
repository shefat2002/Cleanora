import SwiftUI

/// One cleanable item: checkbox, name, risk badge, info button, size.
/// The info button opens WhyInfoSheet with the producer-supplied reason.
/// Large-file rows add a modified-date line and a Reveal in Finder button.
struct CleanupItemRow: View {
    let item: CleanupItem
    /// "Modified Sep 1, 2026" — large-file rows only; nil hides the line.
    var modifiedLine: String? = nil
    /// Present only for large-file rows; nil hides the button.
    var onReveal: (() -> Void)? = nil
    let onToggle: (Bool) -> Void
    let onWhy: () -> Void

    var body: some View {
        HStack(spacing: Design.spacingM) {
            Toggle(isOn: Binding(
                get: { item.selected },
                set: { onToggle($0) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("\(item.selected ? "Deselect" : "Select") \(item.name)")
            .accessibilityHint(hint)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let modifiedLine {
                    Text(modifiedLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .help(item.path.path)

            RiskBadge(level: item.riskLevel)

            Spacer(minLength: Design.spacingS)

            if let onReveal {
                Button(action: onReveal) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(item.name) in Finder")
                .accessibilityHint("Shows the file selected in Finder. Nothing is deleted.")
            }

            Button(action: onWhy) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Why can I remove this?")
            .accessibilityLabel("About \(item.name)")
            .accessibilityHint("Explains why this item can be removed.")

            Text(item.size.formattedByteCount)
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityValue(accessibilitySummary)
    }

    private var hint: String {
        item.riskLevel == .review
            ? "Review item — off until you select it."
            : "Safe to remove; included in the total below."
    }

    /// Large files announce size and date together so the row is meaningful
    /// over VoiceOver without color or column layout.
    private var accessibilitySummary: String {
        guard let modifiedLine else { return item.size.formattedByteCount }
        return "\(item.size.formattedByteCount), \(modifiedLine.lowercased())"
    }
}
