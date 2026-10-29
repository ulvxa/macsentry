import SwiftUI

struct SizeText: View {
    enum Style {
        case body, card, stat, hero
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let bytes: Int64
    var style: Style = .body

    init(_ bytes: Int64, style: Style = .body) {
        self.bytes = bytes
        self.style = style
    }

    var body: some View {
        let formatted = ByteFormat.string(bytes)
        Group {
            if style == .body {
                Text(formatted).monospacedDigit()
            } else {
                split(formatted)
            }
        }
        .contentTransition(reduceMotion ? .identity : .numericText())
    }

    private func split(_ formatted: String) -> some View {
        let parts = formatted.split(separator: " ", omittingEmptySubsequences: true)
        let number = parts.dropLast().joined(separator: " ")
        let unit = parts.last.map(String.init) ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(number.isEmpty ? formatted : number)
                .font(numberFont)
                .monospacedDigit()
                .foregroundStyle(.primary)
            if !number.isEmpty {
                Text(unit)
                    .font(unitFont)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var numberFont: Font {
        switch style {
        case .hero: .heroNumber
        case .stat: .statNumber
        case .card, .body: .cardNumber
        }
    }

    private var unitFont: Font {
        switch style {
        case .hero: .title2
        case .stat: .title3
        case .card, .body: .callout
        }
    }
}
