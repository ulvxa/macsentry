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
            Text(full)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
