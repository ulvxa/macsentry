import Charts
import MacSentryCore
import SwiftUI

struct SparklineView: View {
    let sparkline: Sparkline?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let sparkline, sparkline.points.count >= 2, let low = sparkline.minPoint, let high = sparkline.maxPoint {
            chart(sparkline, low: low, high: high)
        } else {
            Text("Collecting data…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .center)
        }
    }

    static let height: CGFloat = 64

    private func chart(_ sparkline: Sparkline, low: SparklinePoint, high: SparklinePoint) -> some View {
        let lower = Double(low.freeBytes)
        let upper = Double(high.freeBytes)
        let padding = max((upper - lower) * 0.1, 1)
        let segments = sparkline.segments
        return Chart {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                ForEach(segment, id: \.bucketStart) { point in
                    LineMark(
                        x: .value("Time", point.bucketStart),
                        y: .value("Free", Double(point.freeBytes)),
                        series: .value("Segment", index),
                    )
                    .foregroundStyle(.primary)
                    .lineStyle(StrokeStyle(lineWidth: contrast == .increased ? 2 : 1.5, lineCap: .round, lineJoin: .round))
                }
                if segment.count == 1, let only = segment.first {
                    PointMark(x: .value("Time", only.bucketStart), y: .value("Free", Double(only.freeBytes)))
                        .symbolSize(10)
                        .foregroundStyle(.primary)
                }
            }
            PointMark(x: .value("Time", low.bucketStart), y: .value("Free", lower))
                .symbolSize(24)
                .foregroundStyle(.primary)
                .annotation(position: .bottom, overflowResolution: .init(x: .fit, y: .fit)) {
                    Text("Low \(MenuBarFormatting.compactFree(low.freeBytes))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            PointMark(x: .value("Time", high.bucketStart), y: .value("Free", upper))
                .symbolSize(24)
                .foregroundStyle(.primary)
                .annotation(position: .top, overflowResolution: .init(x: .fit, y: .fit)) {
                    Text("High \(MenuBarFormatting.compactFree(high.freeBytes))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: (lower - padding) ... (upper + padding))
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Free space over the last 30 days. Lowest \(MenuBarFormatting.spokenSize(low.freeBytes)), "
                + "highest \(MenuBarFormatting.spokenSize(high.freeBytes)).",
        )
    }
}
