import SwiftUI

enum CheckState: Equatable {
    case on, off, mixed

    var systemImage: String {
        switch self {
        case .on: "checkmark.square.fill"
        case .off: "square"
        case .mixed: "minus.square.fill"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .on: "checked"
        case .off: "unchecked"
        case .mixed: "mixed"
        }
    }
}

struct CheckboxCell: View {
    let state: CheckState
    var isEnabled = true
    let label: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: state.systemImage)
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityValue(state.accessibilityValue)
        .accessibilityAddTraits(.isToggle)
    }
}
