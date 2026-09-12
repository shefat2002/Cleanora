import SwiftUI

/// Checkbox for group selection: all / some / none. VoiceOver reads the
/// group name as the label and the selection state as the value.
struct TriStateCheckButton: View {
    let state: TriStateSelection
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                .frame(width: 18)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Toggles everything in this group.")
    }

    private var symbolName: String {
        switch state {
        case .all: return "checkmark.square.fill"
        case .some: return "minus.square.fill"
        case .none: return "square"
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .all: return "All selected"
        case .some: return "Some selected"
        case .none: return "None selected"
        }
    }
}
