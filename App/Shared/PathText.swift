import MacSentryCore
import SwiftUI

struct PathText: View {
    enum Style {
        case row, block
    }

    @Environment(\.homeURL) private var homeURL

    let url: URL
    var style: Style = .row

    init(_ url: URL, style: Style = .row) {
        self.url = url
        self.style = style
    }

    var body: some View {
        let full = url.path(percentEncoded: false)
        let shown = homeURL.map { UserPath.abbreviate(url, homeURL: $0) } ?? full
        switch style {
        case .row:
            Text(shown)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(full)
        case .block:
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(full)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                PathBar(url: url)
            }
        }
    }
}

/// Clickable path: each segment opens that folder in Finder, the last one reveals the item itself.
struct PathBar: View {
    let url: URL

    var body: some View {
        let chain = FinderTarget.chain(of: url)
        ScrollView(.horizontal) {
            HStack(spacing: Space.xs) {
                ForEach(Array(chain.enumerated()), id: \.offset) { offset, segment in
                    if offset > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    let isLast = offset == chain.count - 1
                    Button(FinderTarget.displayName(of: segment)) {
                        if isLast {
                            FinderActions.reveal([segment])
                        } else {
                            FinderActions.openFolder(segment)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isLast ? .primary : .secondary)
                    .help(isLast ? "Reveal in Finder" : "Open \(segment.path(percentEncoded: false)) in Finder")
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.trailing)
    }
}
