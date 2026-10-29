import SwiftUI

struct DryRunBadge: View {
    var body: some View {
        Label("Dry run", systemImage: "eye")
            .labelStyle(.titleAndIcon)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 8)
            .help("Dry run: nothing is moved on disk")
            .accessibilityLabel("Dry run mode, nothing is moved on disk")
    }
}
