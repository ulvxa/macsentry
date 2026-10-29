import MacSentryCore
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        DuplicatesContent(model: DuplicatesModel(app: app))
    }
}

private struct DuplicatesContent: View {
    @Environment(AppModel.self) private var app
    @State var model: DuplicatesModel

    var body: some View {
        @Bindable var app = app
        Group {
            switch model.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noScan:
                ScanCallToAction(sectionTitle: "duplicate files")
            case .scanningNoData:
                ScanningPlaceholder()
            case let .failed(message):
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: "Couldn't load results",
                    message: message,
                    action: .init(title: "Try Again") { model.retry() },
                )
            case .loaded:
                loaded
            }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Filter by name or path")
        .inspector(isPresented: $app.isInspectorPresented) {
            CandidateInspector(
                candidates: model.focusedCandidates,
                groupName: { _ in "Identical files" },
                quickLook: { candidate in model.quickLookURL = candidate.url },
                extra: { candidate in DuplicateInspectorSection(model: model, candidate: candidate) },
            )
            .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .quickLookPreview(url: $model.quickLookURL, in: model.previewURLs)
        .sheet(item: $model.confirmation) { confirmation in
            QuarantineConfirmSheet(confirmation: confirmation) {
                Task { await model.confirm(confirmation) }
            }
        }
        .sheet(item: $model.failureReport) { report in
            QuarantineFailureSheet(report: report)
        }
        .focusedSceneValue(\.screenActions, model.screenActions)
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
        .onChange(of: app.currentSessionID) { _, sessionID in
            model.sessionChanged(to: sessionID)
        }
    }

    private var minSize: String {
        ByteFormat.string(app.settings.store.duplicateMinSizeBytes)
    }

    private var loaded: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if model.isSkippedForSession {
                Label("Duplicate search was skipped. Scan again to include it.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.l)
                    .padding(.top, Space.s)
            }
            if model.groups.isEmpty {
                EmptyStateView(
                    symbol: "doc.on.doc",
                    title: "No duplicates found",
                    message: "No identical files above \(minSize) in your chosen folders.",
                )
                .frame(maxHeight: .infinity)
            } else if model.visibleGroups.isEmpty {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "No matching duplicates",
                    message: "No copy has \"\(model.query)\" in its name or path.",
                    action: .init(title: "Clear Filter") { model.query = "" },
                )
                .frame(maxHeight: .infinity)
            } else {
                DuplicatesTable(model: model)
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if !model.groups.isEmpty {
                actionBar
            }
        }
    }

    private var actionBar: some View {
        let blocked = model.blockedGroups
        return SelectionActionBar(
            itemCount: model.checkedCandidates.count,
            bytes: model.checkedBytes,
            chipText: blocked.isEmpty ? nil : DuplicatesModel.keepOneCopyReason,
            primary: SelectionAction(
                title: model.primaryTitle,
                shortTitle: model.primaryShortTitle,
                systemImage: "archivebox",
                disabledReason: blocked.first.map { "\(DuplicatesModel.keepOneCopyReason): \($0.name) has no copy left to keep" }
                    ?? model.quarantineDisabledReason,
                hint: "Moves every copy except the keeper to the MacSentry quarantine folder. Nothing is deleted.",
            ) {
                Task { await model.quarantineChecked() }
            },
            clear: { model.clearChecks() },
        )
    }
}

private struct DuplicatesTable: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: DuplicatesModel

    var body: some View {
        Table(of: DuplicateTableRow.self, selection: $model.focusedIDs) {
            TableColumn("") { row in
                switch row.kind {
                case let .group(group):
                    CheckboxCell(
                        state: model.checkState(of: group),
                        isEnabled: model.isCheckable(group),
                        label: "Select extra copies of \(group.name)",
                    ) {
                        model.toggleCheck(group)
                    }
                    .help(group.isSpaceEfficient ? Self.cloneHelp : "Quarantine every copy except the keeper")
                case let .member(member):
                    KeeperRadio(isKeeper: member.isKeeper, isEnabled: !model.isChangingKeeper, name: member.name) {
                        Task { await model.setKeeper(member) }
                    }
                }
            }
            .width(36)
            TableColumn("Name") { row in
                DuplicateNameCell(row: row)
            }
            .width(min: 160, ideal: 220)
            TableColumn("Location") { row in
                switch row.kind {
                case let .group(group):
                    Text("\(group.members.count.formatted()) copies")
                        .foregroundStyle(.secondary)
                case let .member(member):
                    PathText(member.url.deletingLastPathComponent())
                }
            }
            .width(min: 140, ideal: 260)
            TableColumn("Created") { row in
                if case let .member(member) = row.kind {
                    RelativeDateText(member.created)
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Size") { row in
                switch row.kind {
                case let .group(group): SizeText(group.group.fileSize)
                case let .member(member): SizeText(member.size)
                }
            }
            .width(min: 70, ideal: 90)
            .alignment(.numeric)
            TableColumn("Reclaimable") { row in
                ReclaimableCell(row: row)
            }
            .width(min: 100, ideal: 220)
        } rows: {
            ForEach(model.tableRows) { row in
                DisclosureTableRow(row, isExpanded: expansion(for: row)) {
                    ForEach(row.children) { child in
                        TableRow(child)
                    }
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: DuplicateTableRow.ID.self) { ids in
            DuplicateContextMenu(model: model, ids: ids)
        } primaryAction: { _ in
            app.toggleInspector()
        }
        .onKeyPress(.space) {
            guard !model.focusedIDs.isEmpty else { return .ignored }
            model.toggleQuickLook()
            return .handled
        }
    }

    static let cloneHelp = "These copies are APFS clones. They share storage, so quarantining them frees almost nothing."

    private func expansion(for row: DuplicateTableRow) -> Binding<Bool> {
        guard case let .group(groupID) = row.id else { return .constant(false) }
        return Binding(get: { model.isExpanded(groupID) }, set: { model.setExpanded(groupID, $0) })
    }
}

private struct DuplicateContextMenu: View {
    let model: DuplicatesModel
    let ids: Set<DuplicateTableRow.ID>

    var body: some View {
        let urls = model.urls(for: ids)
        Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(urls) }
        Button("Quick Look", systemImage: "eye") { model.quickLook(ids) }
        if ids.count == 1, let id = ids.first, let member = model.member(for: id), !member.isKeeper {
            Button("Set as Keeper", systemImage: "largecircle.fill.circle") {
                Task { await model.setKeeper(member) }
            }
        }
        Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPaths(urls) }
    }
}

private struct DuplicateNameCell: View {
    let row: DuplicateTableRow

    var body: some View {
        switch row.kind {
        case let .group(group):
            HStack(spacing: Space.s) {
                Text(group.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if group.isKeeperMissing {
                    Label("Keeper missing", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("The kept copy is gone. Choose another keeper before quarantining this group.")
                }
            }
            .accessibilityElement(children: .combine)
        case let .member(member):
            HStack(spacing: Space.s) {
                Image(nsImage: FinderActions.icon(for: member.url))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(member.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(member.isKeeper ? "\(member.name), keeper" : member.name)
        }
    }
}

private struct ReclaimableCell: View {
    let row: DuplicateTableRow

    var body: some View {
        switch row.kind {
        case let .group(group):
            if group.isSpaceEfficient {
                Label("Already space efficient (APFS clones)", systemImage: "square.on.square")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(DuplicatesTable.cloneHelp)
            } else {
                SizeText(group.reclaimable)
                    .fontWeight(.semibold)
            }
        case let .member(member):
            if member.isKeeper {
                Text("Kept")
                    .foregroundStyle(.secondary)
            } else {
                let shared = member.size > 0 && member.freeable * 20 < member.size
                SizeText(member.freeable)
                    .foregroundStyle(shared ? .secondary : .primary)
                    .help(shared ? "Shared with APFS clones or hard links" : ByteFormat.string(member.freeable))
            }
        }
    }
}

struct KeeperRadio: View {
    let isKeeper: Bool
    var isEnabled = true
    let name: String
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Image(systemName: isKeeper ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isKeeper)
        .help(isKeeper ? "This copy is kept" : "Keep this copy instead")
        .accessibilityLabel("Keep \(name)")
        .accessibilityAddTraits(isKeeper ? [.isButton, .isSelected] : .isButton)
    }
}

private struct DuplicateInspectorSection: View {
    let model: DuplicatesModel
    let candidate: Candidate

    var body: some View {
        if let groupID = candidate.dupGroupID, let group = model.group(groupID),
           let member = group.members.first(where: { $0.path == candidate.url.path(percentEncoded: false) }) {
            VStack(alignment: .leading, spacing: Space.l) {
                Button(member.isKeeper ? "Kept Copy" : "Set as Keeper", systemImage: "largecircle.fill.circle") {
                    Task { await model.setKeeper(member) }
                }
                .buttonStyle(.bordered)
                .buttonSizing(.flexible)
                .disabled(member.isKeeper || model.isChangingKeeper)
                InspectorSection(title: "Identical copies") {
                    ForEach(group.members.filter { $0.path != member.path }) { other in
                        HStack(spacing: Space.s) {
                            if other.isKeeper {
                                Image(systemName: "largecircle.fill.circle")
                                    .accessibilityLabel("Keeper")
                            }
                            PathText(other.url)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                FinderActions.reveal([other.url])
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .help("Reveal in Finder")
                        }
                    }
                }
                if group.isSpaceEfficient {
                    Text(DuplicatesTable.cloneHelp)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
