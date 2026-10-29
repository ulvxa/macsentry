import SwiftUI

struct DryRunBadge: View {
    enum Style {
        case toolbar, tag
    }

    var style: Style = .toolbar

    var body: some View {
        switch style {
        case .toolbar:
            label
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 8)
        case .tag:
            label
                .font(.caption.weight(.medium))
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.xs / 2)
                .background(.quaternary, in: .capsule)
        }
    }

    private var label: some View {
        Label("Dry run", systemImage: "eye")
            .help("Dry run: nothing is moved on disk")
            .accessibilityLabel("Dry run mode, nothing is moved on disk")
    }
}
