import SwiftUI

/// A drag edits `draft` only and commits `value` once on release; keyboard and accessibility steps commit at once.
struct DraftSlider<Label: View, ValueLabel: View>: View {
    @Binding var value: Double
    @Binding var draft: Double?
    let bounds: ClosedRange<Double>
    var step: Double?
    @ViewBuilder var label: () -> Label
    @ViewBuilder var minimumValueLabel: () -> ValueLabel
    @ViewBuilder var maximumValueLabel: () -> ValueLabel

    @State private var isEditing = false

    var body: some View {
        if let step {
            Slider(
                value: position, in: bounds, step: step,
                label: label, minimumValueLabel: minimumValueLabel, maximumValueLabel: maximumValueLabel,
                onEditingChanged: editingChanged,
            )
        } else {
            Slider(
                value: position, in: bounds,
                label: label, minimumValueLabel: minimumValueLabel, maximumValueLabel: maximumValueLabel,
                onEditingChanged: editingChanged,
            )
        }
    }

    private var position: Binding<Double> {
        Binding(
            get: { draft ?? value },
            set: { newValue in
                if isEditing {
                    draft = newValue
                } else {
                    value = newValue
                }
            },
        )
    }

    private func editingChanged(_ editing: Bool) {
        isEditing = editing
        guard !editing, let pending = draft else { return }
        draft = nil
        value = pending
    }
}

extension DraftSlider {
    init(
        value: Binding<Double>,
        draft: Binding<Double?>,
        in bounds: ClosedRange<Double>,
        step: Double? = nil,
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder minimumValueLabel: @escaping () -> ValueLabel,
        @ViewBuilder maximumValueLabel: @escaping () -> ValueLabel,
    ) {
        self.init(
            value: value, draft: draft, bounds: bounds, step: step,
            label: label, minimumValueLabel: minimumValueLabel, maximumValueLabel: maximumValueLabel,
        )
    }
}

extension DraftSlider where ValueLabel == EmptyView {
    init(
        value: Binding<Double>,
        draft: Binding<Double?>,
        in bounds: ClosedRange<Double>,
        step: Double? = nil,
        @ViewBuilder label: @escaping () -> Label,
    ) {
        self.init(
            value: value, draft: draft, bounds: bounds, step: step,
            label: label, minimumValueLabel: { EmptyView() }, maximumValueLabel: { EmptyView() },
        )
    }
}
