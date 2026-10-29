import MacSentryCore
import SwiftUI

struct FailureReport: Identifiable {
    struct Reason: Identifiable {
        let id: String
        let title: String
        let message: String
        let urls: [URL]
    }

    let id = UUID()
    let title: String
    let reasons: [Reason]

    init(title: String, reasons: [Reason]) {
        self.title = title
        self.reasons = reasons
    }

    init(result: QuarantineResult) {
        let verb = result.moved.isEmpty ? "Nothing" : "\(result.moved.count.formatted()) moved"
        title = "\(verb), \(result.failed.count.formatted()) could not be moved"
        reasons = MoveFailure.allCases.compactMap { failure in
            let urls = result.failed.filter { $0.reason == failure }.map(\.path)
            guard !urls.isEmpty else { return nil }
            return Reason(id: failure.rawValue, title: failure.title, message: failure.message, urls: urls)
        }
    }

    init(doneCount: Int, verb: String, failures: [EntryFailure]) {
        let done = doneCount == 0 ? "Nothing" : "\(doneCount.formatted()) \(verb)"
        title = "\(done), \(failures.count.formatted()) could not be \(verb)"
        reasons = EntryFailureReason.allCases.compactMap { reason in
            let matching = failures.filter { $0.reason == reason }
            guard !matching.isEmpty else { return nil }
            return Reason(
                id: reason.rawValue,
                title: reason.title,
                message: reason.errorDescription ?? "",
                urls: matching.compactMap(\.path),
            )
        }
    }

    var plainText: String {
        ([title] + reasons.flatMap { reason in
            ["", "\(reason.title): \(reason.message)"] + reason.urls.map { "  " + $0.path(percentEncoded: false) }
        }).joined(separator: "\n")
    }
}

extension MoveFailure {
    var title: String {
        switch self {
        case .protected: "Protected"
        case .missing: "No longer exists"
        case .appRunning: "App is running"
        case .permissionDenied: "Permission denied"
        case .locked: "Locked"
        case .changedSinceScan: "Changed since the scan"
        case .destinationExists: "Already exists"
        case .crossDevice: "On another disk"
        case .dataless: "Stored in iCloud"
        case .unknown: "Unexpected error"
        }
    }

    var message: String {
        switch self {
        case .protected: "MacSentry never moves this location."
        case .missing: "It was removed after the scan, so it was skipped."
        case .appRunning: "Quit the app and try again."
        case .permissionDenied: "macOS blocked access. Grant Full Disk Access or remove it yourself."
        case .locked: "The item is locked. Unlock it in Finder with Get Info, then try again."
        case .changedSinceScan: "Its size changed by more than 10 percent. Scan again to review it."
        case .destinationExists: "Something is already at the destination."
        case .crossDevice: "Quarantine only works on the same disk. Remove it yourself if you are sure."
        case .dataless: "The file is not downloaded. Moving it would trigger a download, so it was skipped."
        case .unknown: "Something went wrong. Check the log for details."
        }
    }
}

extension EntryFailureReason {
    var title: String {
        switch self {
        case .notFound: "Record missing"
        case .missing: "No longer in quarantine"
        case .alreadyTrashed: "Already in the Trash"
        case .alreadyRestored: "Already restored"
        case .destinationExists: "Already exists"
        case .permissionDenied: "Permission denied"
        case .outsideQuarantine: "Outside the quarantine folder"
        case .dryRunMode: "Dry run"
        case .unknown: "Unexpected error"
        }
    }
}

struct QuarantineFailureSheet: View {
    @Environment(\.dismiss) private var dismiss

    let report: FailureReport

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(report.title)
                .font(.title3.weight(.semibold))
            List {
                ForEach(report.reasons) { reason in
                    Section {
                        ForEach(reason.urls, id: \.self) { url in
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(url.lastPathComponent).font(.callout)
                                PathText(url)
                            }
                            .contextMenu {
                                Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal([url]) }
                                Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPaths([url]) }
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(reason.title).font(.headline)
                            Text(reason.message).font(.callout).foregroundStyle(.secondary)
                        }
                        .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 200, maxHeight: 420)
            HStack(spacing: Space.s) {
                Spacer()
                Button("Copy Details") { FinderActions.copy(report.plainText) }
                    .buttonStyle(.glass)
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .accessibilityLabel(report.title)
    }
}
