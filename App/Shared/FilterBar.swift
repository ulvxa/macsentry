import MacSentryCore
import SwiftUI

struct FilterBar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("filterBar.collapsed") private var collapsedPreference = false
    @State private var expandedOverride = false

    @Binding var filter: FilterState
    let defaults: FilterState
    let controls: [FilterControl]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if !isCollapsed, ageLabel != nil || sizeLabel != nil {
                HStack(alignment: .top, spacing: Space.xl) {
                    if let ageLabel {
                        AgeThresholdControl(label: ageLabel, days: $filter.minAgeDays)
                            .frame(maxWidth: .infinity)
                    }
                    if let sizeLabel {
                        SizeThresholdControl(label: sizeLabel, bytes: $filter.minSizeBytes)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            HStack(spacing: Space.m) {
                if isCollapsed {
                    Text(filter.summary(controls: controls.filter { $0 != .tiers }))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                } else if ageLabel != nil {
                    AgePresetChips(days: $filter.minAgeDays)
                }
                if controls.contains(.tiers) {
                    if ageLabel != nil || isCollapsed {
                        Divider().frame(height: 16)
                    }
                    TierChips(tiers: $filter.tiers)
                }
                Spacer(minLength: 0)
                if differsFromDefaults {
                    Button("Reset Filters") { reset() }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
                if ageLabel != nil || sizeLabel != nil {
                    Button {
                        toggleCollapsed()
                    } label: {
                        Label("Filters", systemImage: isCollapsed ? "chevron.down" : "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .help(isCollapsed ? "Show filters" : "Hide filters")
                }
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .glassEffect(.regular, in: isCollapsed ? AnyShape(.capsule) : AnyShape(.rect(cornerRadius: Radius.card)))
        .focusSection()
    }

    private var ageLabel: String? {
        controls.lazy.compactMap {
            if case let .age(label) = $0 {
                label
            } else {
                nil
            }
        }.first
    }

    private var sizeLabel: String? {
        controls.lazy.compactMap {
            if case let .size(label) = $0 {
                label
            } else {
                nil
            }
        }.first
    }

    private var isShortWindow: Bool {
        model.windowSize.height > 0 && model.windowSize.height < 700
    }

    private var isCollapsed: Bool {
        collapsedPreference || (isShortWindow && !expandedOverride)
    }

    private var differsFromDefaults: Bool {
        filter.minAgeDays != defaults.minAgeDays || filter.minSizeBytes != defaults.minSizeBytes || filter.tiers != defaults.tiers
    }

    private func reset() {
        filter.minAgeDays = defaults.minAgeDays
        filter.minSizeBytes = defaults.minSizeBytes
        filter.tiers = defaults.tiers
    }

    private func toggleCollapsed() {
        if isCollapsed {
            collapsedPreference = false
            expandedOverride = true
        } else {
            collapsedPreference = true
            expandedOverride = false
        }
    }
}

struct AgeThresholdControl: View {
    let label: String
    @Binding var days: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Space.s)
                Text(days > 0 ? "\(days) days" : "Any age")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .contentTransition(.identity)
                Stepper(label, value: $days, in: FilterState.ageRange, step: 1)
                    .labelsHidden()
                    .controlSize(.small)
            }
            Slider(
                value: Binding(get: { Double(days) }, set: { days = Int($0.rounded()) }),
                in: Double(FilterState.ageRange.lowerBound) ... Double(FilterState.ageRange.upperBound),
                step: 1,
            ) {
                Text(label)
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityValue(days > 0 ? "\(days) days" : "Any age")
        }
    }
}

struct AgePresetChips: View {
    @Binding var days: Int

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(FilterState.agePresets, id: \.self) { preset in
                Toggle(isOn: Binding(get: { days == preset }, set: {
                    if $0 {
                        days = preset
                    }
                })) {
                    Text("\(preset) d").monospacedDigit()
                }
                .toggleStyle(.button)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityLabel("\(preset) days")
            }
        }
    }
}

struct SizeThresholdControl: View {
    let label: String
    @Binding var bytes: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Space.s)
                Text(bytes > 0 ? ByteFormat.string(bytes) : "Any size")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(SizeStops.index(for: bytes)) },
                    set: { bytes = SizeStops.values[min(max(Int($0.rounded()), 0), SizeStops.values.count - 1)] },
                ),
                in: 0 ... Double(SizeStops.values.count - 1),
                step: 1,
            ) {
                Text(label)
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityValue(bytes > 0 ? ByteFormat.string(bytes) : "Any size")
            HStack {
                Text("Any")
                Spacer()
                Text("50 GB")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
    }
}

struct TierChips: View {
    @Binding var tiers: Set<Tier>

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(Tier.allCases, id: \.self) { tier in
                Toggle(isOn: Binding(
                    get: { tiers.contains(tier) },
                    set: { isOn in
                        if isOn {
                            tiers.insert(tier)
                        } else {
                            tiers.remove(tier)
                        }
                    },
                )) {
                    TierLabel(tier, style: .compact)
                }
                .toggleStyle(.button)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityLabel("Show \(tier.word) items")
            }
        }
    }
}
