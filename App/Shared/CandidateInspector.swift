import MacSentryCore
import SwiftUI

struct CandidateInspector<Extra: View>: View {
    let candidates: [Candidate]
    var groupName: (Candidate) -> String = { $0.ruleID }
    var blockReason: (Candidate) -> String? = { _ in nil }
    var quickLook: ((Candidate) -> Void)?
    @ViewBuilder var extra: (Candidate) -> Extra

    var body: some View {
        if candidates.isEmpty {
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.trailing",
                description: Text("Select an item to see details."),
            )
        } else if candidates.count == 1, let candidate = candidates.first {
            ScrollView {
                SingleCandidateDetails(
                    candidate: candidate,
                    groupName: groupName(candidate),
                    blockReason: blockReason(candidate),
                    quickLook: quickLook,
                    extra: extra(candidate),
                )
                .padding(Space.l)
            }
        } else {
            ScrollView {
                MultipleCandidateDetails(candidates: candidates)
                    .padding(Space.l)
            }
        }
    }
}

extension CandidateInspector where Extra == EmptyView {
    init(
        candidates: [Candidate],
        groupName: @escaping (Candidate) -> String = { $0.ruleID },
        blockReason: @escaping (Candidate) -> String? = { _ in nil },
        quickLook: ((Candidate) -> Void)? = nil,
    ) {
        self.init(candidates: candidates, groupName: groupName, blockReason: blockReason, quickLook: quickLook) { _ in EmptyView() }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct SingleCandidateDetails<Extra: View>: View {
    let candidate: Candidate
    let groupName: String
    let blockReason: String?
    let quickLook: ((Candidate) -> Void)?
    let extra: Extra
    @State private var showsSizeInfo = false
    @State private var copiedCommand = false

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: candidate.url.path(percentEncoded: false))
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .top, spacing: Space.s) {
                    if candidate.appBundleID != nil {
                        AppIconView(bundleID: candidate.appBundleID, fallback: candidate.url, size: 32)
                    }
                    Text(candidate.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Text("\(candidate.kind.title) · \(candidate.category.title) · \(groupName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TierLabel(candidate.tier)
            }
            if !exists {
                banner("This item no longer exists", systemImage: "questionmark.folder")
            } else if let blockReason {
                banner(blockReason, systemImage: "exclamationmark.triangle")
            }
            Divider()
            InspectorSection(title: "Path") {
                PathText(candidate.url, style: .block)
            }
            InspectorSection(title: "Size") {
                LabeledContent("Logical") { SizeText(candidate.logicalSize) }
                LabeledContent("On disk") { SizeText(candidate.allocatedSize) }
                LabeledContent("Will free") { SizeText(candidate.freeableSize).fontWeight(.semibold) }
                Button {
                    showsSizeInfo = true
                } label: {
                    Label("About these sizes", systemImage: "info.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showsSizeInfo) {
                    Text(
                        "Logical is the size Finder reports. On disk is what the file system has actually allocated. "
                            + "Will free is what you get back: it excludes data shared with APFS clones or hard links outside this item.",
                    )
                    .font(.callout)
                    .padding(Space.l)
                    .frame(width: 280)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            InspectorSection(title: "Dates") {
                LabeledContent("Created") { RelativeDateText(candidate.createdAt) }
                LabeledContent("Modified") { RelativeDateText(candidate.modifiedAt) }
                LabeledContent("Last used") { RelativeDateText(candidate.lastUsedAt) }
            }
            .font(.callout)
            InspectorSection(title: "Rule") {
                Text(candidate.reason)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(candidate.ruleID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            if let command = candidate.resolvedCommand {
                InspectorSection(title: "Command") {
                    Text(command)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: .rect(cornerRadius: Radius.inset))
                }
            }
            extra
            VStack(spacing: Space.s) {
                Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal([candidate.url]) }
                if let quickLook {
                    Button("Quick Look", systemImage: "eye") { quickLook(candidate) }
                }
                Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPaths([candidate.url]) }
                if let command = candidate.resolvedCommand {
                    Button(copiedCommand ? "Copied" : "Copy CLI Command", systemImage: copiedCommand ? "checkmark" : "terminal") {
                        FinderActions.copy(command)
                        copiedCommand = true
                        AccessibilityNotification.Announcement("Command copied").post()
                    }
                    .task(id: copiedCommand) {
                        guard copiedCommand else { return }
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedCommand = false
                    }
                }
            }
            .buttonStyle(.bordered)
            .buttonSizing(.flexible)
            .disabled(!exists)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func banner(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: .rect(cornerRadius: Radius.inset))
    }
}

private struct MultipleCandidateDetails: View {
    let candidates: [Candidate]

    var body: some View {
        let urls = candidates.map(\.url)
        VStack(alignment: .leading, spacing: Space.l) {
            Text(CountFormat.items(candidates.count))
                .font(.title3.weight(.semibold))
            InspectorSection(title: "Will free") {
                SizeText(candidates.reduce(0) { $0 + $1.freeableSize }, style: .card)
            }
            TierSummary(counts: candidates.reduce(into: [:]) { $0[$1.tier, default: 0] += 1 })
            VStack(spacing: Space.s) {
                Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(urls) }
                Button("Copy Paths", systemImage: "doc.on.doc") { FinderActions.copyPaths(urls) }
            }
            .buttonStyle(.bordered)
            .buttonSizing(.flexible)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
