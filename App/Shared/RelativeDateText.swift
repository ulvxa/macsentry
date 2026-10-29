import SwiftUI

struct RelativeDateText: View {
    let date: Date?

    init(_ date: Date?) {
        self.date = date
    }

    var body: some View {
        if let date {
            Text(date, format: .relative(presentation: .named))
                .help(date.formatted(date: .abbreviated, time: .shortened))
        } else {
            Text("Unknown")
                .foregroundStyle(.tertiary)
        }
    }
}
