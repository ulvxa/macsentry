import MacSentryCore
import SwiftUI

struct ScanStatusOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer(spacing: Space.m) {
            if let activity = model.scanActivity {
                ScanHUD(activity: activity)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("scan.status", in: namespace)
            }
            if model.scanActivity == nil, let toast = model.toast {
                ResultToast(toast: toast)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("scan.status", in: namespace)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: model.statusOverlayKind)
        .padding(.bottom, model.bottomChromeInset > 0 ? model.bottomChromeInset + Space.m : Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(model.statusOverlay != .none)
        .onChange(of: model.isScanning) { _, scanning in
            AccessibilityNotification.Announcement(scanning ? "Scan started" : "Scan ended").post()
        }
        .onChange(of: model.scanActivity?.phase) { _, phase in
            if let phase {
                AccessibilityNotification.Announcement(phase.label).post()
            }
        }
    }
}

extension AppModel {
    var statusOverlayKind: Int {
        switch statusOverlay {
        case .none: 0
        case .hud: 1
        case .toast: 2
        }
    }
}

extension ScanActivity {
    var phaseTitle: String {
        guard isHashingDuplicates else { return phase.label }
        if duplicatesSkipped {
            return "Skipping duplicates"
        }
        guard let hashing else { return phase.label }
        return "Hashing duplicates \(hashing.done.formatted()) of \(hashing.total.formatted())"
    }

    var phaseDetail: String {
        if isHashingDuplicates, !duplicatesSkipped, let hashing {
            return " · \(ByteFormat.string(hashing.bytes))"
        }
        return " · \(filesVisited.formatted()) files · \(ByteFormat.string(bytesVisited))"
    }
}

private struct ScanHUD: View {
    @Environment(AppModel.self) private var model
    let activity: ScanActivity

    var body: some View {
        HStack(spacing: Space.l) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: 0) {
                    Text(activity.phaseTitle)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                    Text(activity.phaseDetail)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Text(activity.currentPath.isEmpty ? " " : activity.currentPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentTransition(.identity)
            .transaction { $0.animation = nil }
            .frame(maxWidth: .infinity, alignment: .leading)
            if activity.isHashingDuplicates, !activity.duplicatesSkipped {
                Button("Skip Duplicates") { model.skipDuplicates() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .help("Stop looking for duplicate files and finish the rest of the scan")
            }
            Button("Cancel") { model.cancelScan() }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(width: 520)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scan in progress")
    }
}

private struct ResultToast: View {
    @Environment(AppModel.self) private var model
    @State private var isHovering = false
    let toast: Toast

    var body: some View {
        HStack(spacing: Space.m) {
            message
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case let .scanFinished(summary) = toast.kind, !summary.unreadable.isEmpty {
                Button {
                    model.unreadableReport = UnreadableReport(urls: summary.unreadable)
                } label: {
                    Text("Show").underline()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
                .font(.callout)
            }
            if let action = toast.action {
                Button(action.title) { model.performToastAction() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .fontWeight(.semibold)
            }
            Button {
                model.dismissToast(toast.id)
            } label: {
                Label("Dismiss", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Dismiss")
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(minWidth: 420, maxWidth: 640)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { isHovering = $0 }
        .task(id: toast.id) {
            guard toast.autoDismisses else { return }
            try? await Task.sleep(for: .seconds(12))
            while isHovering, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            model.dismissToast(toast.id)
        }
    }

    @ViewBuilder
    private var message: some View {
        switch toast.kind {
        case let .scanFinished(summary):
            let found = summary.candidateCount == 0
                ? "Nothing found above your thresholds"
                : "Found \(ByteFormat.string(summary.totalFreeable)) in \(CountFormat.items(summary.candidateCount))"
            let unreadable = summary.unreadable.isEmpty ? "" : " · \(summary.unreadable.count.formatted()) unreadable"
            Text("\(found) · \(DurationFormat.string(summary.duration))\(unreadable)")
                .monospacedDigit()
        case let .scanCancelled(hasPrevious):
            Text(hasPrevious ? "Scan cancelled. Showing results from the previous scan." : "Scan cancelled.")
        case let .scanFailed(reason):
            Text("Scan stopped: \(reason)")
        case let .message(text):
            Text(text).monospacedDigit()
        }
    }
}

struct UnreadableListSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: UnreadableReport

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("\(report.urls.count.formatted()) folders could not be read")
                .font(.title3.weight(.semibold))
            Text("macOS blocked access to these folders, so their contents are not in the results. Grant Full Disk Access to include them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(report.urls, id: \.self) { url in
                PathText(url)
                    .contextMenu {
                        Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal([url]) }
                        Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPaths([url]) }
                    }
            }
            .listStyle(.inset)
            .frame(minHeight: 200, maxHeight: 420)
            HStack(spacing: Space.s) {
                Spacer()
                Button("Copy Paths") { FinderActions.copyPaths(report.urls) }
                    .buttonStyle(.glass)
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
    }
}
