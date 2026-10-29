import AppKit
import MacSentryCore
import SwiftUI

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let menuBar = model.menuBar
        let pressure = menuBar.pressure
        VStack(alignment: .leading, spacing: 12) {
            if pressure.isLow {
                LowSpaceRow(thresholdBytes: pressure.alertThresholdBytes)
            }
            FreeSpaceCard(pressure: pressure)
            SummaryRows(totals: menuBar.totals)
            if model.environment.isDryRun {
                DryRunBadge()
            }
            MenuBarButtons(menuBar: menuBar)
        }
        .padding(16)
        .frame(width: 320)
        .task {
            await pressure.refresh()
            await menuBar.refreshTotals()
        }
    }
}

private struct LowSpaceRow: View {
    let thresholdBytes: Int64
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Low disk space", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
            Text("Below \(MenuBarFormatting.compactFree(thresholdBytes)). Run a scan to find space.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.primary.opacity(contrast == .increased ? 0.7 : 0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Warning. Low disk space. Below \(MenuBarFormatting.spokenSize(thresholdBytes))")
        .accessibilityAddTraits(.isStaticText)
    }
}

private struct FreeSpaceCard: View {
    let pressure: DiskPressureController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let latest = pressure.latest {
                header(latest)
                SparklineView(sparkline: pressure.sparkline)
                HStack {
                    Text("30 days ago")
                    Spacer()
                    Text("Now")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else if pressure.readFailed {
                Label("Couldn't read disk space", systemImage: "exclamationmark.triangle")
                    .font(.callout)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func header(_ sample: DiskSample) -> some View {
        let percent = MenuBarFormatting.percentFree(sample)
        let parts = Self.split(sample.importantFree.formatted(.byteCount(style: .file)))
        return HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(parts.number)
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(parts.unit)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .help(
                "Free space including purgeable files such as caches and local snapshots that macOS clears when it needs room. "
                    + "Finder reports the same number.",
            )
            Spacer()
            Text("\(percent)% free")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(MenuBarFormatting.spokenSize(sample.importantFree)) free, \(percent) percent")
    }

    private static func split(_ text: String) -> (number: String, unit: String) {
        guard let space = text.lastIndex(where: \.isWhitespace) else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }
}

private struct SummaryRows: View {
    let totals: MenuBarTotals

    var body: some View {
        VStack(spacing: 4) {
            row("Reclaimable from last scan", value: totals.reclaimable.map(Self.size) ?? "Not scanned")
            row("In quarantine", value: Self.size(totals.inQuarantine))
            row("In Trash", value: Self.size(totals.inTrash))
        }
        .font(.callout)
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

private struct MenuBarButtons: View {
    let menuBar: MenuBarModel
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = menuBar.scanStatus()
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                if case let .scanning(files) = status {
                    Text(files.map { "Scanning… \($0.formatted()) files" } ?? "Scanning…")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        menuBar.cancelScan?()
                    } label: {
                        Label("Cancel Scan", systemImage: "xmark")
                    }
                    .buttonStyle(.glass)
                    .buttonSizing(.flexible)
                } else {
                    Button {
                        Task { await scan() }
                    } label: {
                        Label("Scan Now", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.glassProminent)
                    .buttonSizing(.flexible)
                    .disabled(status == .unavailable || menuBar.startScan == nil)
                }
                HStack(spacing: 8) {
                    Button("Open MacSentry") { openMain(selecting: nil) }
                        .buttonStyle(.glass)
                        .buttonSizing(.flexible)
                    Button("Open Quarantine") { openMain(selecting: .quarantine) }
                        .buttonStyle(.glass)
                        .buttonSizing(.flexible)
                }
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
        }
    }

    private func scan() async {
        await menuBar.startScan?()
        dismissPanel()
        menuBar.openMainWindow()
    }

    private func openMain(selecting item: SidebarItem?) {
        if let item {
            model.selection = item
        }
        dismissPanel()
        menuBar.openMainWindow()
    }

    private func dismissPanel() {
        if let window = NSApp.keyWindow, window is NSPanel {
            window.orderOut(nil)
        }
    }
}
