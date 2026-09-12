import SwiftUI

/// The "Why can I remove this?" sheet (U-08). Category explanation comes
/// from the single SafetyCopy source via `ScanCategory.whyText`; an optional
/// item adds its producer-supplied reason and the recovery semantics of its
/// deletion method.
struct WhyInfoSheet: View {
    let category: ScanCategory
    var item: CleanupItem?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingL) {
            HStack(spacing: Design.spacingM) {
                CategoryIcon(category: category, size: 32)
                Text("Why can I remove this?")
                    .font(.title3.weight(.semibold))
            }
            Text(category.whyText)
                .fixedSize(horizontal: false, vertical: true)

            if let item {
                Divider()
                VStack(alignment: .leading, spacing: Design.spacingS) {
                    Text("About “\(item.name)”")
                        .font(.headline)
                    Text(item.reason)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    recoveryLabel
                }
            }

            HStack {
                Spacer()
                Button("Got it") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Closes this explanation.")
            }
        }
        .padding(28)
        .frame(width: 400)
    }

    @ViewBuilder
    private var recoveryLabel: some View {
        switch item?.deletionMethod {
        case .trashDirectory, .moveToTrash, nil:
            Label(
                "This item is moved to the Trash first — recoverable until you empty it.",
                systemImage: "arrow.uturn.backward.circle"
            )
        case .removeContents:
            Label(
                "Contents are removed permanently; the folder itself is kept and refills as apps need it.",
                systemImage: "trash"
            )
        }
    }
}
