import MacSentryCore
import SwiftUI

struct TierLabel: View {
    enum Style {
        case full, compact, glyph
    }

    let tier: Tier
    var style: Style = .full

    init(_ tier: Tier, style: Style = .full) {
        self.tier = tier
        self.style = style
    }

    var body: some View {
        content
            .help(tier.meaning)
            .accessibilityLabel(tier.word)
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .glyph:
            glyph
        case .full, .compact:
            Label {
                Text(tier.word)
                    .fontWeight(tier == .red ? .semibold : .regular)
            } icon: {
                glyph
            }
            .font(style == .full ? .callout : .caption)
        }
    }

    private var glyph: some View {
        Image(systemName: tier.systemImage)
            .fontWeight(tier == .red ? .semibold : .regular)
            .foregroundStyle(tier == .green ? .secondary : .primary)
    }
}

struct TierSummary: View {
    let counts: [Tier: Int]

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(Tier.allCases, id: \.self) { tier in
                if let count = counts[tier], count > 0 {
                    Label {
                        Text("\(count) \(tier.word)").monospacedDigit()
                    } icon: {
                        Image(systemName: tier.systemImage)
                    }
                    .font(.caption)
                    .help(tier.meaning)
                }
            }
        }
        .foregroundStyle(.secondary)
    }
}
