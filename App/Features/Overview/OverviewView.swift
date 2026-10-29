import MacSentryCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        OverviewContent(model: OverviewModel(app: app))
    }
}

private struct OverviewContent: View {
    static let treemapMinHeight: CGFloat = 320

    @Environment(AppModel.self) private var app
    @State var model: OverviewModel
    @State private var viewportHeight: CGFloat = 0
    @State private var topHeight: CGFloat = 0

    var body: some View {
        Group {
            if app.isReady {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: Space.xl) {
                            OverviewHero(model: model)
                            cards
                        }
                        .frame(maxWidth: 1100, alignment: .leading)
                        .padding(.horizontal, Space.xl)
                        .padding(.top, Space.l)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { topHeight = $0 })
                        if showsTreemap, let treemap = model.treemap {
                            treemapSection(treemap)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { viewportHeight = $0 })
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await model.activate() }
        .onChange(of: app.isReady) { Task { await model.activate() } }
        .onChange(of: app.currentSessionID) { Task { await model.sessionChanged() } }
        .onChange(of: app.totals) { model.reloadOffenders() }
        .onChange(of: app.quarantineTotals) { Task { await model.refreshCapacity() } }
        .onChange(of: app.isScanning) { Task { await model.refreshCapacity() } }
    }

    @ViewBuilder
    private var cards: some View {
        switch model.phase {
        case .loading:
            OverviewCardGrid(cards: model.cards, isPlaceholder: true)
        case .noScan:
            ContentUnavailableView(
                "No scan yet",
                systemImage: "internaldrive",
                description: Text("Run a scan to see what is taking space on your disk."),
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.xxl)
        case .scanningNoData:
            OverviewCardGrid(cards: model.cards, isPlaceholder: true)
        case .nothingFound:
            ContentUnavailableView {
                Label("Nothing found above your thresholds", systemImage: "sparkles")
            } description: {
                Text("Lower the thresholds in Settings to see more.")
            } actions: {
                SettingsLink {
                    Text("Open Settings")
                }
                .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity)
        case .loaded:
            OverviewCardGrid(cards: model.cards)
        }
    }

    private var showsTreemap: Bool {
        switch model.phase {
        case .loading, .nothingFound, .loaded: true
        case .noScan, .scanningNoData: false
        }
    }

    private var treemapHeight: CGFloat {
        max(Self.treemapMinHeight, viewportHeight - topHeight - Space.xl)
    }

    private func treemapSection(_ treemap: TreemapModel) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Disk map")
                .font(.headline)
                .padding(.horizontal, Space.xl)
            TreemapView(model: treemap, breadcrumbInset: Space.xl)
        }
        .frame(height: treemapHeight)
        .padding(.top, Space.xl)
    }
}

private struct OverviewHero: View {
    static let snapshotHelp = "Time Machine and system updates keep local APFS snapshots. "
        + "Files they reference free their space only once macOS removes the snapshot."

    @Environment(AppModel.self) private var app
    let model: OverviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Space.l) {
                freeSpace
                Spacer(minLength: Space.l)
                OverviewScanControl(model: model)
            }
            if let breakdown = model.breakdown {
                DiskUsageBar(breakdown: breakdown)
                    .padding(.top, Space.l)
                DiskLegend(breakdown: breakdown)
                    .padding(.top, Space.m)
            }
            if app.hasLocalSnapshots {
                Label("Space may return after macOS thins local snapshots", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, Space.m)
                    .help(Self.snapshotHelp)
            }
        }
    }

    private var freeSpace: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Free space")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let breakdown = model.breakdown {
                SizeText(breakdown.free, style: .hero)
                    .help("Includes purgeable space macOS can reclaim on demand.")
                Text("\(breakdown.freeFraction.formatted(.percent.precision(.fractionLength(0)))) of \(ByteFormat.string(breakdown.total))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("Unknown")
                    .font(.heroNumber)
                    .foregroundStyle(.tertiary)
                    .redacted(reason: .placeholder)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewScanControl: View {
    @Environment(AppModel.self) private var app
    let model: OverviewModel

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.xs) {
            Group {
                if app.isScanning {
                    Button {
                        app.cancelScan()
                    } label: {
                        Label("Cancel Scan", systemImage: "xmark")
                            .frame(minWidth: 112)
                    }
                    .buttonStyle(.glass)
                    .help("Cancel Scan (Esc)")
                } else {
                    Button {
                        app.startScan()
                    } label: {
                        Label("Scan", systemImage: "magnifyingglass")
                            .frame(minWidth: 112)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!app.canStartScan)
                    .help("Scan (⌘R)")
                }
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            HStack(spacing: Space.xs) {
                Text(model.scanCaption)
                if let date = model.lastScanCaptionDate {
                    RelativeDateText(date)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
