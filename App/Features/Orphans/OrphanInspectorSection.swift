import MacSentryCore
import SwiftUI

struct OrphanInspectorSection: View {
    @Environment(AppModel.self) private var app
    let candidate: Candidate

    var body: some View {
        let details = OrphanDetails(candidate: candidate)
        VStack(alignment: .leading, spacing: Space.l) {
            InspectorSection(title: "Why it looks orphaned") {
                Text("Confidence: \((candidate.confidence ?? .low).title)")
                    .font(.callout.weight(.medium))
                Text(summary(details))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Guessed app") { Text(details.appName).textSelection(.enabled) }
                    .font(.callout)
                LabeledContent("Location") { Text(details.locationTitle) }
                    .font(.callout)
            }
            if !details.isOlderVersion {
                InspectorSection(title: "Checks that found no installed app") {
                    ForEach(OrphanCheck.allCases, id: \.self) { check in
                        let failed = details.failedChecks.contains(check)
                        Label(check.passedTitle, systemImage: failed ? "checkmark" : "minus")
                            .font(.callout)
                            .foregroundStyle(failed ? .primary : .secondary)
                            .help(failed ? check.passedTitle : "Not checked for this item")
                            .accessibilityValue(failed ? "Confirmed" : "Not checked")
                    }
                }
            }
            if !details.notes.isEmpty {
                InspectorSection(title: "Notes") {
                    ForEach(details.notes, id: \.self) { note in
                        Text(note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button("This app is still installed", systemImage: "checkmark.app") {
                Task { await app.addToNeverTouch([candidate]) }
            }
            .buttonStyle(.bordered)
            .buttonSizing(.flexible)
            .help("Adds \(details.appName) to Never Touch so MacSentry stops suggesting it")
        }
    }

    private func summary(_ details: OrphanDetails) -> String {
        if details.isOlderVersion {
            return "A newer version of \(details.appName) is installed. This folder holds data from an older one."
        }
        switch candidate.confidence ?? .low {
        case .high: return "No installed app owns \"\(details.identity)\", and no app from the same vendor is installed."
        case .medium: return "No installed app owns \"\(details.identity)\", but an app from the same vendor is installed."
        case .low: return "No installed app owns \"\(details.identity)\". It could belong to a command line tool. Review it first."
        }
    }
}
