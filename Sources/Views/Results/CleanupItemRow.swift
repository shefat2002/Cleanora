import SwiftUI

/// One cleanable item: checkbox, name, risk badge, info button, size.
/// The info button opens WhyInfoSheet with the producer-supplied reason.
struct CleanupItemRow: View {
    let item: CleanupItem
    let onToggle: (Bool) -> Void
    let onWhy: () -> Void

    var body: some View {
        HStack(spacing: Design.spacingM) {
            Toggle(isOn: Binding(
                get: { item.selected },
                set: onToggle
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("\(item.selected ? "Deselect" : "Select") \(item.name)")
            .accessibilityHint(hint)

            Text(item.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.path.path)

            RiskBadge(level: item.riskLevel)

            Spacer(minLength: Design.spacingS)

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
    }

    private var hint: String {
        item.riskLevel == .review
            ? "Review item — off until you select it."
            : "Safe to remove; included in the total below."
    }
}
