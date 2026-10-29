import Foundation
import MacSentryCore

struct FilterState: Equatable {
    static let ageRange = 0 ... 730
    static let agePresets = [30, 90, 180, 365]
    static let unfiltered = FilterState(minAgeDays: 0, minSizeBytes: 0)

    var minAgeDays: Int
    var minSizeBytes: Int64
    var tiers: Set<Tier> = Set(Tier.allCases)
    var query = ""

    init(minAgeDays: Int, minSizeBytes: Int64, tiers: Set<Tier> = Set(Tier.allCases), query: String = "") {
        self.minAgeDays = min(max(minAgeDays, Self.ageRange.lowerBound), Self.ageRange.upperBound)
        self.minSizeBytes = max(minSizeBytes, 0)
        self.tiers = tiers
        self.query = query
    }

    init(thresholds: Thresholds) {
        self.init(minAgeDays: thresholds.minAgeDays, minSizeBytes: thresholds.minSize)
    }

    func candidateFilter(
        categories: Set<MacSentryCore.Category>,
        actions: Set<CandidateAction> = [],
        controls: [FilterControl],
        ageBasis: AgeBasis,
    ) -> CandidateFilter {
        let usesAge = controls.contains {
            if case .age = $0 {
                true
            } else {
                false
            }
        }
        let usesSize = controls.contains {
            if case .size = $0 {
                true
            } else {
                false
            }
        }
        let usesTiers = controls.contains(.tiers)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return CandidateFilter(
            categories: categories,
            tiers: usesTiers && tiers.count < Tier.allCases.count ? tiers : [],
            actions: actions,
            minFreeable: usesSize ? minSizeBytes : 0,
            minAgeDays: usesAge && minAgeDays > 0 ? minAgeDays : nil,
            ageBasis: ageBasis,
            search: trimmed.isEmpty ? nil : trimmed,
        )
    }

    func summary(controls: [FilterControl]) -> String {
        var parts: [String] = []
        for control in controls {
            switch control {
            case .age: parts.append(minAgeDays > 0 ? "Unused ≥ \(minAgeDays) days" : "Any age")
            case .size: parts.append(minSizeBytes > 0 ? "≥ \(ByteFormat.string(minSizeBytes))" : "Any size")
            case .tiers: parts.append(tiers.count == Tier.allCases.count ? "all tiers" : Tier.allCases.filter(tiers.contains).map(\.word)
                    .joined(separator: ", "))
            }
        }
        return parts.joined(separator: " · ")
    }
}

enum FilterControl: Hashable {
    case age(label: String)
    case size(label: String)
    case tiers

    static let listControls: [FilterControl] = [.age(label: "Unused for at least"), .size(label: "Size at least"), .tiers]
}

enum SizeStops {
    static let values: [Int64] = [
        0, 10_000_000, 20_000_000, 50_000_000, 100_000_000, 200_000_000, 500_000_000,
        1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000, 20_000_000_000, 50_000_000_000,
    ]

    static func index(for bytes: Int64) -> Int {
        guard bytes > 0 else { return 0 }
        let target = log(Double(bytes))
        return values.indices.dropFirst().min { abs(log(Double(values[$0])) - target) < abs(log(Double(values[$1])) - target) } ?? 0
    }
}
