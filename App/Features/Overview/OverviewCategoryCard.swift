import SwiftUI

struct OverviewCardGrid: View {
    @Environment(AppModel.self) private var app
    let cards: [OverviewCard]
    var isPlaceholder = false

    var body: some View {
        GlassEffectContainer(spacing: Space.l) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: Space.l)], alignment: .leading, spacing: Space.l) {
                ForEach(cards) { card in
                    OverviewCategoryCard(card: card, isPlaceholder: isPlaceholder) {
                        app.selection = card.item
                    }
                }
            }
        }
        .redacted(reason: isPlaceholder ? .placeholder : [])
        .allowsHitTesting(!isPlaceholder)
    }
}

struct OverviewCategoryCard: View {
    let card: OverviewCard
    let isPlaceholder: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Label(card.item.title, systemImage: card.item.systemImage)
                        .font(.headline)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if card.isEmpty, !isPlaceholder {
                    Text("Nothing found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    SizeText(card.total.freeable, style: .card)
                    Text(CountFormat.items(card.total.count))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if !card.offenders.isEmpty {
                        Divider()
                        ForEach(card.offenders) { offender in
                            HStack(spacing: Space.s) {
                                Text(offender.name)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: Space.s)
                                Text(ByteFormat.string(offender.freeable))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
            .contentShape(.rect(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Radius.card))
        .accessibilityLabel(card.accessibilityText)
        .accessibilityHint("Opens \(card.item.title)")
    }
}
