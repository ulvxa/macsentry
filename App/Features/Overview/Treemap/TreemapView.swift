import AppKit
import MacSentryCore
import SwiftUI

struct TreemapView: View {
    let model: TreemapModel
    var extendsBackground = true
    var breadcrumbInset: CGFloat = 24

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.crumbs.isEmpty {
                TreemapBreadcrumbBar(model: model)
                    .padding(.horizontal, breadcrumbInset)
            }
            content
        }
        .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .noScan:
            ContentUnavailableView(
                "No disk map yet",
                systemImage: "square.grid.2x2",
                description: Text("Run a scan to see what is taking space on your disk."),
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ProgressView("Building disk map")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            Text(model.crumbs.count > 1 ? "Empty folder" : "No folders were scanned")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't load disk map", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            TreemapCanvasView(model: model)
                .id(model.levelKey)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.levelKey)
                .backgroundExtensionEffect(isEnabled: extendsBackground)
        }
    }
}

private struct TreemapCanvasView: View {
    let model: TreemapModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var tooltipSize: CGSize = .zero

    private static let accessibleTileLimit = 40

    var body: some View {
        GeometryReader { proxy in
            let tiles = model.placedTiles(in: proxy.size)
            let palette = TreemapPalette(colorScheme: colorScheme, increasedContrast: contrast == .increased)
            Canvas { context, _ in
                TreemapPainter(tiles: tiles, palette: palette, hoveredID: model.hoveredTile?.id).paint(&context)
            } symbols: {
                ForEach(Tier.allCases, id: \.self) { tier in
                    Image(systemName: tier.systemImage)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .tag(tier)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case let .active(point): model.updateHover(at: point, in: tiles)
                case .ended: model.updateHover(at: nil, in: tiles)
                }
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { point in
                guard let tile = tiles.first(where: { $0.rect.contains(point) }) else { return }
                let optionHeld = NSEvent.modifierFlags.contains(.option)
                Task { await model.activate(tile, selectingCandidate: optionHeld) }
            }
            .overlay(alignment: .topLeading) {
                if let tile = model.hoveredTile {
                    TreemapTooltip(item: tile.item)
                        .onGeometryChange(for: CGSize.self, of: \.size) { tooltipSize = $0 }
                        .offset(tooltipOffset(in: proxy.size))
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Disk map")
            .accessibilityChildren {
                ForEach(tiles.prefix(Self.accessibleTileLimit)) { tile in
                    Button(tile.item.accessibilityText) {
                        Task { await model.activate(tile, selectingCandidate: false) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tooltipOffset(in canvas: CGSize) -> CGSize {
        let gap = CGSize(width: 12, height: 16)
        var left = model.hoverPoint.x + gap.width
        var top = model.hoverPoint.y + gap.height
        if left + tooltipSize.width > canvas.width {
            left = model.hoverPoint.x - gap.width - tooltipSize.width
        }
        if top + tooltipSize.height > canvas.height {
            top = model.hoverPoint.y - gap.height - tooltipSize.height
        }
        return CGSize(width: max(left, 0), height: max(top, 0))
    }
}

private struct TreemapTooltip: View {
    let item: TreemapItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
            Text(item.sizeText)
                .font(.caption.monospacedDigit())
            if item.isOther {
                Text("\(item.mergedCount) smaller folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(item.candidateText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let tier = item.tier {
                Label(tier.word, systemImage: tier.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if item.candidateURL != nil {
                Text("Option-click to review")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: 260, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

private struct TreemapBreadcrumbBar: View {
    let model: TreemapModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.breadcrumbSegments.enumerated()), id: \.element.id) { offset, segment in
                if offset > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                switch segment {
                case let .crumb(crumb):
                    crumbButton(crumb, isCurrent: crumb == model.crumbs.last)
                case let .overflow(hidden):
                    Menu("...") {
                        ForEach(hidden) { crumb in
                            Button(crumb.name) { Task { await model.navigate(to: crumb) } }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Hidden folders")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .lineLimit(1)
    }

    private func crumbButton(_ crumb: TreemapModel.Crumb, isCurrent: Bool) -> some View {
        Button { Task { await model.navigate(to: crumb) } } label: {
            Text(crumb.name)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .accessibilityLabel(isCurrent ? crumb.name : "Go to \(crumb.name)")
    }
}

struct TreemapPalette: Sendable {
    let colorScheme: ColorScheme
    let increasedContrast: Bool

    func fill(rank: Double) -> Color {
        let widen = increasedContrast ? 0.06 : 0
        let blend = min(max(rank, 0), 1)
        let white = colorScheme == .dark
            ? (0.20 - widen) + (0.22 + 2 * widen) * blend
            : (0.80 - widen) + (0.14 + 2 * widen) * blend
        return Color(white: min(max(white, 0), 1))
    }
}

private struct TreemapPainter {
    let tiles: [TreemapPlacedTile]
    let palette: TreemapPalette
    let hoveredID: String?

    func paint(_ context: inout GraphicsContext) {
        for tile in tiles {
            paint(tile, in: &context)
        }
        if let hovered = tiles.first(where: { $0.id == hoveredID }) {
            let rect = hovered.rect.insetBy(dx: 1, dy: 1)
            guard rect.width > 0, rect.height > 0 else { return }
            context.stroke(Path(rect), with: .color(.primary), lineWidth: 2)
        }
    }

    private func paint(_ tile: TreemapPlacedTile, in context: inout GraphicsContext) {
        let rect = tile.rect.insetBy(dx: 0.5, dy: 0.5)
        guard rect.width > 0, rect.height > 0 else { return }
        let item = tile.item
        context.fill(Path(rect), with: .color(palette.fill(rank: item.sizeRank)))
        if item.isOther {
            context.stroke(
                Path(rect.insetBy(dx: 0.5, dy: 0.5)),
                with: .color(.primary.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3]),
            )
        }
        if item.candidateCount > 0, rect.width > 8, rect.height > 8 {
            context.stroke(Path(rect.insetBy(dx: 3, dy: 3)), with: .color(.primary.opacity(0.85)), lineWidth: 1.5)
        }
        var labelInset: CGFloat = 8
        if let tier = item.tier, item.candidateCount > 0, tile.rect.width >= 60, tile.rect.height >= 40,
           let symbol = context.resolveSymbol(id: tier) {
            context.draw(symbol, at: CGPoint(x: rect.minX + 8, y: rect.minY + 8), anchor: .topLeading)
            labelInset = 26
        }
        if tile.rect.width >= 90, tile.rect.height >= 40 {
            paintLabel(of: item, in: rect, inset: labelInset, context: &context)
        }
    }

    private func paintLabel(of item: TreemapItem, in rect: CGRect, inset: CGFloat, context: inout GraphicsContext) {
        let available = rect.width - inset - 6
        guard available > 20 else { return }
        let origin = CGPoint(x: rect.minX + inset, y: rect.minY + 7)
        let title = item.isOther ? "Other (\(item.mergedCount))" : item.name
        let name = fitted(title, width: available, context: &context) { $0.font(.caption.weight(.medium)).foregroundStyle(.primary) }
        context.draw(name.text, at: origin, anchor: .topLeading)
        let size = context.resolve(Text(item.sizeText).font(.caption2.monospacedDigit()).foregroundStyle(.primary))
        context.draw(size, at: CGPoint(x: origin.x, y: origin.y + name.height + 1), anchor: .topLeading)
    }

    private func fitted(
        _ string: String,
        width: CGFloat,
        context: inout GraphicsContext,
        style: (Text) -> Text,
    ) -> (text: GraphicsContext.ResolvedText, height: CGFloat) {
        let unbounded = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        var candidate = string
        var resolved = context.resolve(style(Text(candidate)))
        var measured = resolved.measure(in: unbounded)
        var attempts = 0
        while measured.width > width, attempts < 6, candidate.count > 1 {
            let keep = max(1, Int(Double(candidate.count) * Double(width / measured.width)) - 1)
            candidate = String(string.prefix(keep)) + "…"
            resolved = context.resolve(style(Text(candidate)))
            measured = resolved.measure(in: unbounded)
            attempts += 1
        }
        return (resolved, measured.height)
    }
}
